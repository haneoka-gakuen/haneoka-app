package org.haneoka.haneoka

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private lateinit var saves: SaveChannel

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
