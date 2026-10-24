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
    private val gravitas by lazy { GravitasLogin(this,::readSecret,::writeSecret) }
    @Volatile private var loginGeneration=0
    @Volatile private var resumed=false
    @Volatile private var recoveryStarting=false
    private val recoveryKey=GravitasLogin.ORIGIN+"/recovery"
    private val recoveryGate by lazy {NativeRecoveryGate({readSecret(recoveryKey)},{writeSecret(recoveryKey,it)})}
    override fun onResume(){super.onResume();resumed=true;worker.execute { StoreNotificationClient.prepare(this) }}
    override fun onPause(){resumed=false;super.onPause()}
    private fun loginResult(value:String){mainHandler.post{platformChannel?.invokeMethod("gravitasResult",value)}}
    private fun browserLogin(register:Boolean,generation:Int,groups:Boolean=false,username:String?=null){
        if(generation!=loginGeneration)return
        val intent=gravitas.begin(register,groups,username)
        mainHandler.post{
            if(!resumed||generation!=loginGeneration){worker.execute{if(generation==loginGeneration){gravitas.failed("canceled");loginResult("canceled")}}}
            else try{startActivity(intent)}catch(_:Exception){worker.execute{gravitas.failed();loginResult("failed")}}
        }
    }
    private fun startLogin(register:Boolean,browserOnly:Boolean,generation:Int,groups:Boolean=false,username:String?=null){
        if(register||browserOnly||groups||!username.isNullOrBlank()){browserLogin(register,generation,groups,username);return}
        if(!resumed||generation!=loginGeneration)return
        val(challenge,state)=gravitas.prepareBroker()
        val result=GravitasBroker(this).authorize(challenge,state)
        if(generation!=loginGeneration)return
        if(!resumed){gravitas.failed("canceled");loginResult("canceled");return}
        when(result){
            is BrokerResult.Authorized -> {
                val value=gravitas.completeBroker(state,result.value,{generation==loginGeneration})
                if(value=="login_required")browserLogin(false,generation) else loginResult(value)
            }
            BrokerResult.Browser -> browserLogin(false,generation)
            BrokerResult.Unavailable -> {gravitas.failed("unavailable");loginResult("unavailable")}
            BrokerResult.Canceled -> {gravitas.failed("canceled");loginResult("canceled")}
        }
    }
    private fun recoverLogin(username:String,generation:Int){
        try {
            if(generation!=loginGeneration)return
            if(!resumed){loginResult("recovery_suppressed");return}
            if(getSharedPreferences("spacetime.preferences",Context.MODE_PRIVATE).getString("spacetime.gravitas.disconnected",null)=="1"){loginResult("recovery_login_required");return}
            val token=readSecret(GravitasLogin.ORIGIN)
            if(token==null){loginResult("recovery_login_required");return}
            when(recoveryGate.begin(token)){
                RecoveryDecision.SUPPRESS->{loginResult("recovery_suppressed");return}
                RecoveryDecision.BLOCKED->{loginResult("recovery_login_required");return}
                RecoveryDecision.START->{}
            }
            val(challenge,state)=gravitas.prepareBroker(true)
            val broker=GravitasBroker(this).authorize(challenge,state)
            if(generation!=loginGeneration)return
            val value=if(!resumed)"suppressed" else when(broker){
                is BrokerResult.Authorized->gravitas.completeBroker(state,broker.value,{generation==loginGeneration},token,username)
                BrokerResult.Unavailable->"unavailable"
                BrokerResult.Canceled->"canceled"
                BrokerResult.Browser->"login_required"
            }
            if(generation!=loginGeneration)return
            recoveryGate.finish(token,value)
            gravitas.finish("recovery_"+value)
            loginResult("recovery_"+value)
        }catch(_:Exception){loginResult("recovery_unavailable")}
        finally{recoveryStarting=false}
    }

    private fun handleAccountIntent(intent:Intent?) {
        val uri=intent?.data ?: return
        if(!GravitasLogin.isCallback(uri)) return
        intent.data=null
        val generation=loginGeneration
        worker.execute {
            if(generation!=loginGeneration)return@execute
            if(getSharedPreferences("spacetime.preferences",Context.MODE_PRIVATE).getString("spacetime.gravitas.disconnected",null)=="1") {
                writeSecret(GravitasLogin.PENDING,null);writeSecret(GravitasLogin.RESULT,null);return@execute
            }
            try { gravitas.callback(uri,{generation==loginGeneration})?.let { value -> mainHandler.post { platformChannel?.invokeMethod("gravitasResult",value) } } }
            catch(_:Exception) { mainHandler.post { platformChannel?.invokeMethod("gravitasResult","failed") } }
        }
    }

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
        handleAccountIntent(intent)
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
        handleAccountIntent(intent)
        platformChannel!!.setMethodCallHandler { call, result ->
                if(call.method=="recoverGravitasLogin"){
                    val username=call.argument<String>("username")
                    if(!resumed||recoveryStarting||username.isNullOrEmpty()){result.success(false);return@setMethodCallHandler}
                    recoveryStarting=true;val generation=++loginGeneration
                    worker.execute{recoverLogin(username,generation)}
                    result.success(true);return@setMethodCallHandler
                }
                if(call.method=="startGravitasLogin"){
                    val generation=++loginGeneration
                    val register=call.argument<Boolean>("register")==true
                    val browserOnly=call.argument<Boolean>("browserOnly")==true
                    val groups=call.argument<Boolean>("groups")==true
                    val username=call.argument<String>("username")
                    worker.execute{try{startLogin(register,browserOnly,generation,groups,username)}catch(_:Exception){gravitas.failed();loginResult("failed")}}
                    result.success(null);return@setMethodCallHandler
                }
                if(call.method=="cancelGravitasLogin")loginGeneration++
                if(call.method=="openCalendarNotificationSettings") {
                    if(Build.VERSION.SDK_INT>=26) {
                        getSystemService(android.app.NotificationManager::class.java).createNotificationChannel(android.app.NotificationChannel("calendar-updates","Invites & event updates",android.app.NotificationManager.IMPORTANCE_DEFAULT))
                        startActivity(Intent(android.provider.Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS).putExtra(android.provider.Settings.EXTRA_APP_PACKAGE,packageName).putExtra(android.provider.Settings.EXTRA_CHANNEL_ID,"calendar-updates"))
                    } else startActivity(Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS,android.net.Uri.parse("package:$packageName")))
                    result.success(null);return@setMethodCallHandler
                }
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
                        val value: Any? = when (call.method) {
                            "initialize" -> mapOf("gravitasResult" to gravitas.takeResult(),"navigation" to calendarNavigation(),"timezone" to TimeZone.getDefault().id,
                                "preferences" to prefs.all.filterValues { it is String })
                            "cancelGravitasLogin" -> { writeSecret(GravitasLogin.PENDING,null);writeSecret(GravitasLogin.RESULT,null);writeSecret(recoveryKey,null);null }
                            "readCalendar" -> CalendarDisk.read(this)?.also { runCatching { StoreNotifications.account(this, org.json.JSONObject(it)) } }
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
                                val arguments=call.arguments as? Map<*,*>
                                if(arguments?.containsKey("expectedToken")!=true || readSecret(server)==call.argument<String>("expectedToken")) writeSecret(server,token)
                                null
                            }
                            "readSession" -> {
                                val server = requireNotNull(call.argument<String>("server"))
                                readSecret(server)
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

    private fun writeSecret(name:String,value:String?) {
        val editor=getSharedPreferences("spacetime.sessions",Context.MODE_PRIVATE).edit()
        if(value==null) editor.remove(sessionName(name)) else {
            val cipher=Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE,sessionKey());cipher.updateAAD(name.toByteArray(Charsets.UTF_8))
            editor.putString(sessionName(name),encode(cipher.iv)+"."+encode(cipher.doFinal(value.toByteArray(Charsets.UTF_8))))
        }
        check(editor.commit())
        if (name == GravitasLogin.ORIGIN && value == null) StoreNotifications.clear(this)
    }
    private fun readSecret(name:String):String? {
        val prefs=getSharedPreferences("spacetime.sessions",Context.MODE_PRIVATE)
        val stored=prefs.getString(sessionName(name),null) ?: return null
        return try {
            val parts=stored.split(".");require(parts.size==2)
            val cipher=Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE,sessionKey(),GCMParameterSpec(128,decode(parts[0])))
            cipher.updateAAD(name.toByteArray(Charsets.UTF_8))
            String(cipher.doFinal(decode(parts[1])),Charsets.UTF_8)
        } catch(_:Exception) { prefs.edit().remove(sessionName(name)).commit();null }
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
