package com.jeethsuresh.spacetime

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.content.Intent
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStore
import java.security.MessageDigest
import java.util.TimeZone
import java.util.concurrent.Executors
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class MainActivity : FlutterActivity() {
    private val worker = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val keyAlias = "spacetime.session.v1"

    private var platformChannel:MethodChannel?=null
    private fun calendarNavigation():Map<String,String>? {
        val uri=intent?.data ?: return null
        if(uri.scheme!="spacetime" || uri.host!="calendar") return null
        val date=uri.getQueryParameter("date") ?: return null
        try { java.time.LocalDate.parse(date) } catch(_:Exception) { return null }
        val view=uri.getQueryParameter("view")?.takeIf { it=="Daily" || it=="Weekly" } ?: "Daily"
        return mapOf("date" to date,"view" to view)
    }
    override fun onNewIntent(intent:Intent) {
        super.onNewIntent(intent);setIntent(intent)
        calendarNavigation()?.let { platformChannel?.invokeMethod("openCalendar",it) }
    }
    private var notificationResult: MethodChannel.Result? = null
    override fun onRequestPermissionsResult(requestCode:Int, permissions:Array<out String>, grantResults:IntArray) {
        super.onRequestPermissionsResult(requestCode,permissions,grantResults)
        if(requestCode==4001) { notificationResult?.success(LocalReminders.allowed(this)); notificationResult=null }
    }
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        platformChannel=MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.jeethsuresh.spacetime/platform")
        platformChannel!!.setMethodCallHandler { call, result ->
                if(call.method=="requestNotifications") {
                    if(Build.VERSION.SDK_INT>=33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)!=PackageManager.PERMISSION_GRANTED) {
                        if(notificationResult!=null) { result.error("busy","Notification permission is already open.",null) }
                        else { notificationResult=result;requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS),4001) }
                    } else result.success(LocalReminders.allowed(this))
                    return@setMethodCallHandler
                }
                worker.execute {
                    try {
                        val prefs = getSharedPreferences("spacetime.preferences", Context.MODE_PRIVATE)
                        val sessions = getSharedPreferences("spacetime.sessions", Context.MODE_PRIVATE)
                        val value: Any? = when (call.method) {
                            "initialize" -> mapOf("navigation" to calendarNavigation(),"timezone" to TimeZone.getDefault().id,
                                "preferences" to prefs.all.filterValues { it is String })
                            "readCalendar" -> CalendarDisk.read(this)
                            "writeCalendar" -> { CalendarDisk.write(this,requireNotNull(call.argument<String>("value")));null }
                            "scheduleReminders" -> { LocalReminders.configure(this,call.argument<Boolean>("enabled")==true,call.argument<List<*>>("events") ?: emptyList<Any>());null }
                            "reminderDiagnostics" -> LocalReminders.diagnostics(this)
                            "writePreference" -> {
                                val key = requireNotNull(call.argument<String>("key"))
                                val value = requireNotNull(call.argument<String>("value"))
                                check(prefs.edit().putString(key, value).commit())
                                CalendarWidgets.refresh(this)
                                null
                            }
                            "writeSession" -> {
                                val server = requireNotNull(call.argument<String>("server"))
                                val token = call.argument<String>("token")
                                val name = sessionName(server)
                                val editor = sessions.edit()
                                if (token == null) editor.remove(name) else {
                                    val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                                    cipher.init(Cipher.ENCRYPT_MODE, sessionKey())
                                    cipher.updateAAD(server.toByteArray(Charsets.UTF_8))
                                    editor.putString(name, encode(cipher.iv) + "." + encode(cipher.doFinal(token.toByteArray(Charsets.UTF_8))))
                                }
                                check(editor.commit())
                                null
                            }
                            "readSession" -> {
                                val server = requireNotNull(call.argument<String>("server"))
                                val name = sessionName(server)
                                val stored = sessions.getString(name, null)
                                if (stored == null) null else try {
                                    val parts = stored.split(".")
                                    require(parts.size == 2)
                                    val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                                    cipher.init(Cipher.DECRYPT_MODE, sessionKey(), GCMParameterSpec(128, decode(parts[0])))
                                    cipher.updateAAD(server.toByteArray(Charsets.UTF_8))
                                    String(cipher.doFinal(decode(parts[1])), Charsets.UTF_8)
                                } catch (_: Exception) {
                                    sessions.edit().remove(name).commit()
                                    null // Restored/corrupted ciphertext requires a new sign-in.
                                }
                            }
                            else -> { mainHandler.post { result.notImplemented() }; return@execute }
                        }
                        mainHandler.post { result.success(value) }
                    } catch (_: Exception) {
                        mainHandler.post { result.error("platform_storage", "Could not access local app storage.", null) }
                    }
                }
            }
    }

    private fun sessionKey(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(keyAlias, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(KeyGenParameterSpec.Builder(keyAlias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256).build())
        return generator.generateKey()
    }
    private fun sessionName(server: String) = encode(MessageDigest.getInstance("SHA-256").digest(server.toByteArray(Charsets.UTF_8)))
    private fun encode(bytes: ByteArray) = Base64.encodeToString(bytes, Base64.NO_WRAP)
    private fun decode(value: String) = Base64.decode(value, Base64.NO_WRAP)

    override fun onDestroy() { worker.shutdown(); super.onDestroy() }
}
