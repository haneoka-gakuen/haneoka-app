package org.haneoka.haneoka

import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
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

/**
 * Reads the game's save files on the phone itself. Since Android 11 the
 * game's `Android/data` folder is readable only by the shell user, which
 * Shizuku lends to apps; on Android 8–12 the system folder picker can also
 * grant that one folder. Only listing and reading run, under the game's own
 * `files/<account>` folders.
 */
class SaveChannel(private val activity: Activity, messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, "org.haneoka/saves")
    private val worker = Executors.newSingleThreadExecutor()
    private val errors = Executors.newSingleThreadExecutor()
    private val timeouts = Executors.newSingleThreadScheduledExecutor()
    private val imports = File(activity.cacheDir, "save-imports").apply { mkdirs() }
    private val batches = mutableMapOf<String, File>()
    @Volatile private var disposed = false
    private var pendingGrant: MethodChannel.Result? = null
    private var pendingPermission: MethodChannel.Result? = null
    private val permissionListener = Shizuku.OnRequestPermissionResultListener { code, result ->
        if (code == SHIZUKU_REQUEST) {
            val pending = pendingPermission
            pendingPermission = null
            pending?.success(result == PackageManager.PERMISSION_GRANTED)
        }
    }

    init {
        channel.setMethodCallHandler(this)
        Shizuku.addRequestPermissionResultListener(permissionListener)
    }

    fun dispose() {
        disposed = true
        pendingPermission?.error("cancelled", "Activity closed", null)
        pendingPermission = null
        pendingGrant?.success(null)
        pendingGrant = null
        Shizuku.removeRequestPermissionResultListener(permissionListener)
        channel.setMethodCallHandler(null)
        worker.execute {
            errors.shutdownNow()
            timeouts.shutdownNow()
            synchronized(batches) {
                batches.values.forEach { removeBatch(it) }
                batches.clear()
            }
        }
        worker.shutdown()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "shizukuStatus" -> result.success(shizukuStatus())
                "shizukuRequest" -> {
                    if (shizukuStatus() != "needsPermission") result.success(shizukuStatus() == "ready")
                    else {
                        check(pendingPermission == null) { "Permission request already open" }
                        pendingPermission = result
                        try {
                            Shizuku.requestPermission(SHIZUKU_REQUEST)
                        } catch (error: Exception) {
                            pendingPermission = null
                            throw error
                        }
                    }
                }
                "openShizuku" -> {
                    val intent = activity.packageManager.getLaunchIntentForPackage(SHIZUKU_PACKAGE)
                    if (intent != null) activity.startActivity(intent)
                    result.success(intent != null)
                }
                "shizukuRead" -> readBatch(result) { folder -> shizukuRead(call.argument<String>("package")!!, folder) }
                "canGrantGameFolder" -> result.success(Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU)
                "grantGameFolder" -> grantGameFolder(call.argument<String>("package")!!, result)
                "grantedFolders" -> result.success(
                    activity.contentResolver.persistedUriPermissions.filter { it.isReadPermission }.map { it.uri.toString() },
                )
                "readFolder" -> readBatch(result) { folder -> readTree(Uri.parse(call.argument<String>("uri")!!), folder) }
                "releaseRead" -> background(result) {
                    val folder = synchronized(batches) { batches.remove(call.argument<String>("id")) }
                    folder?.let { removeBatch(it) }
                    null
                }
                else -> result.notImplemented()
            }
        } catch (error: Exception) {
            result.error("read_failed", error.message, null)
        }
    }

    private fun readBatch(result: MethodChannel.Result, read: (File) -> List<Map<String, Any?>>) {
        background(result) {
            val folder = synchronized(activeImports) {
                imports.listFiles()?.filter { it.name !in activeImports }?.forEach { it.deleteRecursively() }
                Files.createTempDirectory(imports.toPath(), "read-").toFile().also { activeImports.add(it.name) }
            }
            try {
                val files = read(folder)
                if (disposed) throw IOException("Activity closed")
                synchronized(batches) { batches[folder.name] = folder }
                mapOf("id" to folder.name, "files" to files)
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

    private fun background(result: MethodChannel.Result, work: () -> Any?) {
        worker.execute {
            val outcome = runCatching(work)
            activity.runOnUiThread {
                if (!disposed) outcome.fold({ result.success(it) }, { result.error("read_failed", it.message, null) })
            }
        }
    }

    private fun shizukuStatus(): String = try {
        when {
            !Shizuku.pingBinder() -> "notRunning"
            Shizuku.isPreV11() -> "unsupported"
            Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED -> "ready"
            else -> "needsPermission"
        }
    } catch (_: Throwable) {
        "notRunning"
    }

    /** Every small file in the package's account folders, with its size and time. */
    private fun shizukuRead(packageId: String, folder: File): List<Map<String, Any?>> {
        require(packageId in PACKAGES) { "unknown package" }
        check(shizukuStatus() == "ready") { "Shizuku is unavailable" }
        val root = "/sdcard/Android/data/$packageId/files"
        val top = run("ls", "-1p", root) ?: return emptyList()
        val out = ArrayList<Map<String, Any?>>()
        for (dir in top.lines().filter { it.endsWith("/") }.map { it.dropLast(1) }.filter { ACCOUNT_DIR.matches(it) }) {
            val path = "$root/$dir"
            val listing = run("ls", "-1p", path) ?: continue
            for (name in listing.lines().filter { it.isNotEmpty() && !it.endsWith("/") }) {
                val file = "$path/$name"
                val stat = run("stat", "-c", "%s %Y", file)?.trim()?.split(" ") ?: continue
                val size = stat.firstOrNull()?.toLongOrNull() ?: continue
                if (size <= 0 || size > MAX_FILE) continue
                val staged = File(folder, out.size.toString())
                val complete = staged.outputStream().use { output ->
                    process(arrayOf("cat", file)) { input -> copy(input, output) }
                }
                if (complete != true) {
                    staged.delete()
                    continue
                }
                out += mapOf(
                    "source" to "$packageId/$dir/$name",
                    "group" to "$packageId/$dir",
                    "modified" to (stat.getOrNull(1)?.toLongOrNull()?.times(1000)),
                    "package" to packageId,
                    "path" to staged.path,
                )
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
        if (disposed) throw IOException("Activity closed")
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
            if (disposed) throw IOException("Activity closed")
            val n = input.read(buffer)
            if (n < 0) return true
            total += n
            if (total > MAX_FILE) return false
            output.write(buffer, 0, n)
        }
    }

    /** Opens the system folder picker on the game's folder; one tap grants it for good. */
    private fun grantGameFolder(packageId: String, result: MethodChannel.Result) {
        require(packageId in PACKAGES) { "unknown package" }
        check(pendingGrant == null) { "Folder picker already open" }
        val initial = DocumentsContract.buildDocumentUri(STORAGE, "primary:Android/data/$packageId")
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
            .putExtra(DocumentsContract.EXTRA_INITIAL_URI, initial)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
        @Suppress("DEPRECATION")
        activity.startActivityForResult(intent, GRANT_REQUEST)
        pendingGrant = result
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != GRANT_REQUEST) return false
        val pending = pendingGrant
        pendingGrant = null
        val tree = data?.data
        try {
            if (resultCode == Activity.RESULT_OK && tree != null) {
                if (data.flags and Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION != 0) {
                    activity.contentResolver.takePersistableUriPermission(tree, Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
                pending?.success(tree.toString())
            } else {
                pending?.success(null)
            }
        } catch (error: Exception) {
            pending?.error("read_failed", error.message, null)
        }
        return true
    }

    /** Walks a granted folder: in the game's own tree only `files/<account>` is entered. */
    private fun readTree(tree: Uri, folder: File): List<Map<String, Any?>> {
        val resolver = activity.contentResolver
        val rootId = DocumentsContract.getTreeDocumentId(tree)
        val packageId = PACKAGES.firstOrNull { rootId == "primary:Android/data/$it" || rootId.startsWith("primary:Android/data/$it/") }
        val out = ArrayList<Map<String, Any?>>()
        fun walk(docId: String, path: String, depth: Int) {
            if (depth > 6) return
            if (disposed) throw IOException("Activity closed")
            val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, docId)
            val columns = arrayOf(
                Document.COLUMN_DOCUMENT_ID, Document.COLUMN_DISPLAY_NAME, Document.COLUMN_MIME_TYPE,
                Document.COLUMN_SIZE, Document.COLUMN_LAST_MODIFIED,
            )
            val rows = ArrayList<Array<Any?>>()
            resolver.query(children, columns, null, null, null)?.use { c ->
                while (c.moveToNext()) rows += arrayOf(c.getString(0), c.getString(1), c.getString(2), c.getLong(3), c.getLong(4))
            }
            for ((id, name, mime, size, modified) in rows.map { Row(it) }) {
                if (mime == Document.MIME_TYPE_DIR) {
                    if (name in SKIPPED) continue
                    if (packageId != null && name != "files" && !ACCOUNT_DIR.matches(name)) continue
                    walk(id, "$path/$name", depth + 1)
                } else if (size in 1..MAX_FILE) {
                    val staged = File(folder, out.size.toString())
                    val complete = resolver.openInputStream(DocumentsContract.buildDocumentUriUsingTree(tree, id))?.use { input ->
                        staged.outputStream().use { output -> copy(input, output) }
                    }
                    if (complete != true) {
                        staged.delete()
                        continue
                    }
                    out += mapOf("source" to "$path/$name", "group" to path, "modified" to modified, "package" to packageId, "path" to staged.path)
                }
            }
        }
        walk(rootId, packageId ?: rootId, 0)
        return out
    }

    private class Row(values: Array<Any?>) {
        val id = values[0] as String
        val name = (values[1] as String?) ?: ""
        val mime = values[2] as String?
        val size = values[3] as Long
        val modified = values[4] as Long
        operator fun component1() = id
        operator fun component2() = name
        operator fun component3() = mime
        operator fun component4() = size
        operator fun component5() = modified
    }

    companion object {
        private val activeImports = mutableSetOf<String>()
        private const val SHIZUKU_REQUEST = 7301
        private const val GRANT_REQUEST = 7302
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
