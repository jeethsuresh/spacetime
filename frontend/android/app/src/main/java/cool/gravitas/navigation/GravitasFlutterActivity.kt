package cool.gravitas.navigation

import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** Keep this host in every Flutter Android app, including cached-engine hosts. */
open class GravitasFlutterActivity : FlutterActivity() {
    private var navigation: MethodChannel? = null
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        navigation = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "cool.gravitas/navigation")
    }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        GravitasEdgeNavigation.install(this, { onBackPressed() }, { navigation?.invokeMethod("forward", null) })
    }
}
