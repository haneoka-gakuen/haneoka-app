package org.haneoka.haneoka

import android.content.Intent
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterShellArgs

class MainActivity : FlutterActivity() {
    private lateinit var saves: SaveChannel

    override fun getFlutterShellArgs(): FlutterShellArgs = super.getFlutterShellArgs().apply {
        // Use the legacy renderer for Intel Android graphics translation.
        if (Build.SUPPORTED_ABIS.any { it == "x86" || it == "x86_64" }) {
            remove(FlutterShellArgs.ARG_ENABLE_IMPELLER)
            add(FlutterShellArgs.ARG_DISABLE_IMPELLER)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        saves = SaveChannel(this, flutterEngine.dartExecutor.binaryMessenger)
    }

    @Deprecated("Activity results from the system folder picker")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (!saves.onActivityResult(requestCode, resultCode, data)) super.onActivityResult(requestCode, resultCode, data)
    }

    override fun onDestroy() {
        if (::saves.isInitialized) saves.dispose()
        super.onDestroy()
    }
}
