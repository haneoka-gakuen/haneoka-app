package org.haneoka.device

import android.app.Activity
import android.content.Intent
import android.content.pm.ActivityInfo
import android.content.pm.PackageManager
import android.graphics.Color
import android.net.Uri
import android.os.Build
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import android.view.View
import android.view.ViewGroup
import android.webkit.WebView
import androidx.activity.result.ActivityResult
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.webkit.ProxyConfig
import androidx.webkit.ProxyController
import androidx.webkit.WebViewFeature
import app.tauri.annotation.ActivityCallback
import app.tauri.annotation.Command
import app.tauri.annotation.InvokeArg
import app.tauri.annotation.TauriPlugin
import app.tauri.plugin.Invoke
import app.tauri.plugin.JSArray
import app.tauri.plugin.JSObject
import app.tauri.plugin.Plugin
import moe.shizuku.server.IShizukuService
import rikka.shizuku.Shizuku
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.nio.file.Files
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

@InvokeArg
class PackageArgs {
    lateinit var packageId: String
}

@InvokeArg
class FolderArgs {
    lateinit var uri: String
}

@InvokeArg
class BatchArgs {
    lateinit var id: String
}

@InvokeArg
class BarsArgs {
    var color: String? = null
    var dark: Boolean = false
}

@InvokeArg
class ActiveArgs {
    var active: Boolean = false
}

@InvokeArg
class ProxyArgs {
    var port: Int = 0
}

@InvokeArg
class OrientationArgs {
    var orientation: String = "any"
}

/**
 * Reads the game's save files on the phone itself. Since Android 11 the
 * game's `Android/data` folder is readable only by the shell user, which
 * Shizuku lends to apps; on Android 8–12 the system folder picker can also
 * grant that one folder. Only listing and reading run, under the game's own
 * `files/<account>` folders. Also: system bar colours, fullscreen and
 * orientation for the page.
 */
@TauriPlugin
class DevicePlugin(private val activity: Activity) : Plugin(activity) {
    private val worker = Executors.newSingleThreadExecutor()
    private val errors = Executors.newSingleThreadExecutor()
    private val timeouts = Executors.newSingleThreadScheduledExecutor()
    private val imports = File(activity.cacheDir, "save-imports").apply { mkdirs() }
    private val batches = mutableMapOf<String, File>()
    private var pendingPermission: Invoke? = null
    private val permissionListener = Shizuku.OnRequestPermissionResultListener { code, result ->
        if (code == SHIZUKU_REQUEST) {
            val pending = pendingPermission
            pendingPermission = null
            pending?.resolve(JSObject().put("granted", result == PackageManager.PERMISSION_GRANTED))
        }
    }

    private var container: View? = null
    @Volatile private var fullscreenActive = false

    override fun load(webView: WebView) {
        Shizuku.addRequestPermissionResultListener(permissionListener)
        // Android 15 draws every app edge to edge: the page sits inside the
        // system bars and display cutout, which show the page's bar colour.
        val root = (webView.parent as? ViewGroup) ?: webView
        container = root
        ViewCompat.setOnApplyWindowInsetsListener(root) { view, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout())
            val ime = insets.getInsets(WindowInsetsCompat.Type.ime())
            if (fullscreenActive) view.setPadding(0, 0, 0, 0)
            else view.setPadding(bars.left, bars.top, bars.right, maxOf(bars.bottom, ime.bottom))
            WindowInsetsCompat.CONSUMED
        }
        root.post { ViewCompat.requestApplyInsets(root) }
    }

    private fun background(invoke: Invoke, work: () -> JSObject) {
        worker.execute {
            val outcome = runCatching(work)
            activity.runOnUiThread {
                outcome.fold({ invoke.resolve(it) }, { invoke.reject(it.message ?: "read_failed") })
            }
        }
    }

    private fun shizukuStatusText(): String = try {
        when {
            !Shizuku.pingBinder() -> "notRunning"
            Shizuku.isPreV11() -> "unsupported"
            Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED -> "ready"
            else -> "needsPermission"
        }
    } catch (_: Throwable) {
        "notRunning"
    }

    @Command
    fun shizukuStatus(invoke: Invoke) {
        invoke.resolve(
            JSObject()
                .put("status", shizukuStatusText())
                .put("canGrantFolder", Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU)
                .put("installed", activity.packageManager.getLaunchIntentForPackage(SHIZUKU_PACKAGE) != null),
        )
    }

    @Command
    fun shizukuRequest(invoke: Invoke) {
        val status = shizukuStatusText()
        if (status != "needsPermission") {
            invoke.resolve(JSObject().put("granted", status == "ready"))
            return
        }
        if (pendingPermission != null) {
            invoke.reject("Permission request already open")
            return
        }
        pendingPermission = invoke
        try {
            Shizuku.requestPermission(SHIZUKU_REQUEST)
        } catch (error: Exception) {
            pendingPermission = null
            invoke.reject(error.message ?: "shizuku")
        }
    }

    @Command
    fun openShizuku(invoke: Invoke) {
        val intent = activity.packageManager.getLaunchIntentForPackage(SHIZUKU_PACKAGE)
        if (intent != null) activity.startActivity(intent)
        invoke.resolve(JSObject().put("opened", intent != null))
    }

    @Command
    fun shizukuRead(invoke: Invoke) {
        val args = invoke.parseArgs(PackageArgs::class.java)
        readBatch(invoke) { folder -> shizukuRead(args.packageId, folder) }
    }

    @Command
    fun grantedFolders(invoke: Invoke) {
        val folders = JSArray()
        activity.contentResolver.persistedUriPermissions.filter { it.isReadPermission }.forEach { folders.put(it.uri.toString()) }
        invoke.resolve(JSObject().put("folders", folders))
    }

    /** Opens the system folder picker on the game's folder; one tap grants it for good. */
    @Command
    fun grantGameFolder(invoke: Invoke) {
        val args = invoke.parseArgs(PackageArgs::class.java)
        if (args.packageId !in PACKAGES) {
            invoke.reject("unknown package")
            return
        }
        val initial = DocumentsContract.buildDocumentUri(STORAGE, "primary:Android/data/${args.packageId}")
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
            .putExtra(DocumentsContract.EXTRA_INITIAL_URI, initial)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
        startActivityForResult(invoke, intent, "grantResult")
    }

    @ActivityCallback
    fun grantResult(invoke: Invoke, result: ActivityResult) {
        val tree = result.data?.data
        try {
            if (result.resultCode == Activity.RESULT_OK && tree != null) {
                activity.contentResolver.takePersistableUriPermission(tree, Intent.FLAG_GRANT_READ_URI_PERMISSION)
                invoke.resolve(JSObject().put("uri", tree.toString()))
            } else {
                invoke.resolve(JSObject())
            }
        } catch (error: Exception) {
            invoke.reject(error.message ?: "read_failed")
        }
    }

    @Command
    fun readFolder(invoke: Invoke) {
        val args = invoke.parseArgs(FolderArgs::class.java)
        readBatch(invoke) { folder -> readTree(Uri.parse(args.uri), folder) }
    }

    @Command
    fun releaseRead(invoke: Invoke) {
        val args = invoke.parseArgs(BatchArgs::class.java)
        background(invoke) {
            synchronized(batches) { batches.remove(args.id) }?.let { removeBatch(it) }
            JSObject()
        }
    }

    @Command
    fun systemBars(invoke: Invoke) {
        val args = invoke.parseArgs(BarsArgs::class.java)
        activity.runOnUiThread {
            val window = activity.window
            val color = runCatching { Color.parseColor(args.color) }.getOrNull()
            if (color != null) {
                container?.setBackgroundColor(color)
                window.decorView.setBackgroundColor(color)
                if (Build.VERSION.SDK_INT < 35) {
                    @Suppress("DEPRECATION")
                    window.statusBarColor = color
                    @Suppress("DEPRECATION")
                    window.navigationBarColor = color
                }
            }
            val controller = WindowCompat.getInsetsController(window, window.decorView)
            controller.isAppearanceLightStatusBars = !args.dark
            controller.isAppearanceLightNavigationBars = !args.dark
            invoke.resolve()
        }
    }

    @Command
    fun fullscreen(invoke: Invoke) {
        val args = invoke.parseArgs(ActiveArgs::class.java)
        activity.runOnUiThread {
            val window = activity.window
            val controller = WindowCompat.getInsetsController(window, window.decorView)
            fullscreenActive = args.active
            container?.let { ViewCompat.requestApplyInsets(it) }
            if (args.active) {
                controller.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
                controller.hide(WindowInsetsCompat.Type.systemBars())
            } else {
                controller.show(WindowInsetsCompat.Type.systemBars())
                activity.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
            }
            invoke.resolve()
        }
    }

    /** Sends the web view's requests through the app's loopback route; local pages stay direct. */
    @Command
    fun webViewProxy(invoke: Invoke) {
        val args = invoke.parseArgs(ProxyArgs::class.java)
        if (args.port <= 0 || !WebViewFeature.isFeatureSupported(WebViewFeature.PROXY_OVERRIDE)) {
            invoke.resolve(JSObject().put("applied", false))
            return
        }
        val config = ProxyConfig.Builder()
            .addProxyRule("127.0.0.1:${args.port}")
            .addBypassRule("tauri.localhost")
            .addBypassRule("*.localhost")
            .addBypassRule("127.0.0.1")
            .build()
        ProxyController.getInstance().setProxyOverride(config, { it.run() }) {
            invoke.resolve(JSObject().put("applied", true))
        }
    }

    @Command
    fun orientation(invoke: Invoke) {
        val args = invoke.parseArgs(OrientationArgs::class.java)
        activity.runOnUiThread {
            activity.requestedOrientation = when {
                args.orientation.startsWith("landscape") -> ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
                args.orientation.startsWith("portrait") -> ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
                else -> ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
            }
            invoke.resolve()
        }
    }

    private fun readBatch(invoke: Invoke, read: (File) -> List<JSObject>) {
        background(invoke) {
            val folder = synchronized(activeImports) {
                imports.listFiles()?.filter { it.name !in activeImports }?.forEach { it.deleteRecursively() }
                Files.createTempDirectory(imports.toPath(), "read-").toFile().also { activeImports.add(it.name) }
            }
            try {
                val files = JSArray()
                read(folder).forEach { files.put(it) }
                synchronized(batches) { batches[folder.name] = folder }
                JSObject().put("id", folder.name).put("files", files)
            } catch (error: Exception) {
                removeBatch(folder)
                throw error
            }
        }
    }

    private fun removeBatch(folder: File) {
        synchronized(activeImports) {
            folder.deleteRecursively()
            activeImports.remove(folder.name)
        }
    }

    private fun staged(source: String, group: String, modified: Long?, packageId: String?, file: File): JSObject =
        JSObject()
            .put("source", source)
            .put("group", group)
            .put("modified", modified ?: 0L)
            .put("package", packageId ?: "")
            .put("path", file.path)

    /** Every small file in the package's account folders, with its size and time. */
    private fun shizukuRead(packageId: String, folder: File): List<JSObject> {
        require(packageId in PACKAGES) { "unknown package" }
        check(shizukuStatusText() == "ready") { "Shizuku is unavailable" }
        val root = "/sdcard/Android/data/$packageId/files"
        val top = run("ls", "-1p", root) ?: return emptyList()
        val out = ArrayList<JSObject>()
        for (dir in top.lines().filter { it.endsWith("/") }.map { it.dropLast(1) }.filter { ACCOUNT_DIR.matches(it) }) {
            val path = "$root/$dir"
            val listing = run("ls", "-1p", path) ?: continue
            for (name in listing.lines().filter { it.isNotEmpty() && !it.endsWith("/") }) {
                val file = "$path/$name"
                val stat = run("stat", "-c", "%s %Y", file)?.trim()?.split(" ") ?: continue
                val size = stat.firstOrNull()?.toLongOrNull() ?: continue
                if (size <= 0 || size > MAX_FILE) continue
                val target = File(folder, out.size.toString())
                val complete = target.outputStream().use { output -> process(arrayOf("cat", file)) { input -> copy(input, output) } }
                if (complete != true) {
                    target.delete()
                    continue
                }
                out += staged("$packageId/$dir/$name", "$packageId/$dir", stat.getOrNull(1)?.toLongOrNull()?.times(1000), packageId, target)
            }
        }
        return out
    }

    private fun run(vararg argv: String): String? = process(argv) { input ->
        val output = ByteArrayOutputStream()
        if (!copy(input, output)) throw IOException("File listing is too large")
        output.toString("UTF-8")
    }

    /** Runs argv as the shell user, without a shell, so paths need no quoting. */
    private fun <T> process(argv: Array<out String>, read: (InputStream) -> T): T? {
        val service = IShizukuService.Stub.asInterface(Shizuku.getBinder()) ?: throw IOException("Shizuku disconnected")
        val process = service.newProcess(arrayOf(*argv), null, null)
        val timedOut = AtomicBoolean(false)
        val timeout = timeouts.schedule({
            timedOut.set(true)
            runCatching { process.destroy() }
        }, 30, TimeUnit.SECONDS)
        val stderr = errors.submit {
            ParcelFileDescriptor.AutoCloseInputStream(process.errorStream).use { input ->
                val buffer = ByteArray(4096)
                while (input.read(buffer) >= 0) { }
            }
        }
        try {
            val value = ParcelFileDescriptor.AutoCloseInputStream(process.inputStream).use(read)
            val status = process.waitFor()
            stderr.get(5, TimeUnit.SECONDS)
            if (timedOut.get()) throw IOException("Shizuku read timed out")
            return if (status == 0) value else null
        } finally {
            timeout.cancel(false)
            runCatching { process.destroy() }
            stderr.cancel(true)
        }
    }

    private fun copy(input: InputStream, output: OutputStream): Boolean {
        val buffer = ByteArray(64 * 1024)
        var total = 0L
        while (true) {
            val n = input.read(buffer)
            if (n < 0) return true
            total += n
            if (total > MAX_FILE) return false
            output.write(buffer, 0, n)
        }
    }

    /** Walks a granted folder: in the game's own tree only `files/<account>` is entered. */
    private fun readTree(tree: Uri, folder: File): List<JSObject> {
        val resolver = activity.contentResolver
        val rootId = DocumentsContract.getTreeDocumentId(tree)
        val packageId = PACKAGES.firstOrNull { rootId == "primary:Android/data/$it" || rootId.startsWith("primary:Android/data/$it/") }
        val out = ArrayList<JSObject>()
        fun walk(docId: String, path: String, depth: Int) {
            if (depth > 6) return
            val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, docId)
            val columns = arrayOf(
                Document.COLUMN_DOCUMENT_ID, Document.COLUMN_DISPLAY_NAME, Document.COLUMN_MIME_TYPE,
                Document.COLUMN_SIZE, Document.COLUMN_LAST_MODIFIED,
            )
            val rows = ArrayList<Array<Any?>>()
            resolver.query(children, columns, null, null, null)?.use { c ->
                while (c.moveToNext()) rows += arrayOf(c.getString(0), c.getString(1), c.getString(2), c.getLong(3), c.getLong(4))
            }
            for (row in rows) {
                val id = row[0] as String
                val name = (row[1] as String?) ?: ""
                val mime = row[2] as String?
                val size = row[3] as Long
                val modified = row[4] as Long
                if (mime == Document.MIME_TYPE_DIR) {
                    if (name in SKIPPED) continue
                    if (packageId != null && name != "files" && !ACCOUNT_DIR.matches(name)) continue
                    walk(id, "$path/$name", depth + 1)
                } else if (size in 1..MAX_FILE) {
                    val target = File(folder, out.size.toString())
                    val complete = resolver.openInputStream(DocumentsContract.buildDocumentUriUsingTree(tree, id))?.use { input ->
                        target.outputStream().use { output -> copy(input, output) }
                    }
                    if (complete != true) {
                        target.delete()
                        continue
                    }
                    out += staged("$path/$name", path, modified, packageId, target)
                }
            }
        }
        walk(rootId, packageId ?: rootId, 0)
        return out
    }

    companion object {
        private val activeImports = mutableSetOf<String>()
        private const val SHIZUKU_REQUEST = 7301
        private const val SHIZUKU_PACKAGE = "moe.shizuku.privileged.api"
        private const val STORAGE = "com.android.externalstorage.documents"
        private const val MAX_FILE = 16L shl 20
        private val PACKAGES = listOf("com.bilibili.sirius.official", "com.bilibili.sirius", "com.bushiroad.sirius")
        private val ACCOUNT_DIR = Regex("^[0-9a-fA-F]{16,128}$")
        private val SKIPPED = setOf(
            "EncryptedBundles", "Addressables", "Master", "RemoteCatalog", "il2cpp", "Unity", "UnityCache", "cache", "tmp",
            "com.unity3d.player",
        )
    }
}
