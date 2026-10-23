package com.jeethsuresh.spacetime

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.util.Base64
import org.json.JSONObject
import java.net.URL
import java.security.MessageDigest
import java.security.SecureRandom
import javax.net.ssl.HttpsURLConnection

/** System-browser authorization; the browser never receives an app bearer token. */
class GravitasLogin(private val context: Context, private val vaultRead:(String)->String?, private val vaultWrite:(String,String?)->Unit, private val exchange:(String,String)->JSONObject = ::exchangeNative) {
    companion object {
        const val ORIGIN = "https://spacetime.gravitas.cool"
        const val PENDING = "gravitas.pending.v1"
        const val RESULT = "gravitas.result.v1"
        fun isCallback(uri:Uri?) = uri?.scheme=="cool.gravitas.spacetime" && uri.authority==null && uri.path=="/auth/callback" && uri.fragment==null
        private fun random():String = Base64.encodeToString(ByteArray(32).also { SecureRandom().nextBytes(it) },Base64.NO_WRAP or Base64.URL_SAFE or Base64.NO_PADDING)
    }
    private fun prepare(mode:String):Pair<String,String> {
        val verifier=random();val state=random()
        vaultWrite(PENDING,JSONObject().put("mode",mode).put("verifier",verifier).put("state",state).put("expires",System.currentTimeMillis()+600000).toString())
        vaultWrite(RESULT,null)
        val challenge=Base64.encodeToString(MessageDigest.getInstance("SHA-256").digest(verifier.toByteArray(Charsets.US_ASCII)),Base64.NO_WRAP or Base64.URL_SAFE or Base64.NO_PADDING)
        return Pair(challenge,state)
    }
    internal fun prepareBroker(recovery:Boolean=false):Pair<String,String> = prepare(if(recovery)"recovery" else "broker")
    fun begin(register:Boolean,groups:Boolean=false):Intent {
        val (challenge,state)=prepare("browser")
        val uri=Uri.parse("$ORIGIN/auth/gravitas/start").buildUpon().appendQueryParameter("native_challenge",challenge).appendQueryParameter("native_state",state)
        if(register) uri.appendQueryParameter("screen","register")
        if(groups) uri.appendQueryParameter("groups","1")
        return Intent(Intent.ACTION_VIEW,uri.build()).addCategory(Intent.CATEGORY_BROWSABLE)
    }
    fun callback(uri:Uri,stillCurrent:()->Boolean = {true}):String? {
        if(!isCallback(uri)) return null
        val pending=vaultRead(PENDING)?.let { JSONObject(it) } ?: return null
        if(pending.optString("mode","browser")!="browser") return null
        // Ignore forged callbacks without consuming the real transaction.
        if(uri.queryParameterNames.any { it !in setOf("state","code","result") } || uri.queryParameterNames.any { uri.getQueryParameters(it).size!=1 } ||
            !MessageDigest.isEqual((uri.getQueryParameter("state") ?: "").toByteArray(),pending.getString("state").toByteArray())) return null
        vaultWrite(PENDING,null)
        var result="failed"
        try {
            check(System.currentTimeMillis()<pending.getLong("expires"))
            if(uri.getQueryParameter("result")!="connected") {
                result=uri.getQueryParameter("result")?.takeIf { it in setOf("access_denied","login_required","consent_required","unavailable") } ?: "failed"
            } else {
                val code=uri.getQueryParameter("code") ?: error("missing code")
                check(code.matches(Regex("^[a-f0-9]{48}$")))
                val response=exchange(code,pending.getString("verifier"))
                if(!stillCurrent()) return null
                store(response)
                result="connected"
            }
        } catch(_:Exception) { result="failed" }
        if(!stillCurrent())return null
        vaultWrite(RESULT,result)
        return result
    }
    fun takeResult():String? = vaultRead(RESULT)?.also { vaultWrite(RESULT,null) }
    fun finish(result:String) { vaultWrite(PENDING,null);vaultWrite(RESULT,result) }
    fun failed(result:String="failed") = finish(result)
    private fun store(response:JSONObject) {
        val token=response.getString("token")
        check(token.matches(Regex("^[a-f0-9]{48}$")) && response.getJSONObject("user").getString("username").isNotEmpty())
        vaultWrite("$ORIGIN/user",response.getJSONObject("user").toString())
        vaultWrite(ORIGIN,token)
    }
    internal fun completeBroker(state:String,code:BrokerCode,stillCurrent:()->Boolean,recoveryToken:String?=null,expectedUsername:String?=null,redeem:(JSONObject)->JSONObject = {body->nativeRequest("/api/auth/gravitas/broker",body,recoveryToken)}):String {
        val pending=vaultRead(PENDING)?.let{JSONObject(it)} ?: return "canceled"
        if(!stillCurrent() || pending.optString("mode")!=(if(recoveryToken!=null)"recovery" else "broker") || pending.getString("state")!=state) return "canceled"
        val result=try {
            check(System.currentTimeMillis()<pending.getLong("expires"))
            val body=JSONObject().put("code",code.code).put("code_verifier",pending.getString("verifier")).put("session_id",code.sessionId).put("sub",code.subject)
            if(recoveryToken!=null)body.put("recovery",true)
            val response=redeem(body)
            if(!stillCurrent()) return "canceled"
            if(recoveryToken!=null && response.getJSONObject("user").getString("username")!=expectedUsername)return "login_required"
            store(response);"connected"
        } catch(e:NativeLoginException) {if(e.status==401)"login_required" else "unavailable"}
          catch(_:java.io.IOException) {"unavailable"}
          catch(_:Exception) {"failed"}
        vaultWrite(PENDING,null);vaultWrite(RESULT,result)
        return result
    }
}

private fun java.io.InputStream.readBytesLimited(limit:Int):ByteArray {
    val output=java.io.ByteArrayOutputStream()
    val buffer=ByteArray(4096)
    while(true) { val count=read(buffer);if(count<0)break;check(output.size()+count<=limit);output.write(buffer,0,count) }
    return output.toByteArray()
}

private fun exchangeNative(code:String, verifier:String):JSONObject {
    return nativeRequest("/api/auth/gravitas/android",JSONObject().put("code",code).put("code_verifier",verifier))
}
private class NativeLoginException(val status:Int):Exception()
private fun nativeRequest(path:String,body:JSONObject,token:String?=null):JSONObject {
    val connection=URL(GravitasLogin.ORIGIN+path).openConnection() as HttpsURLConnection
    try {
        connection.instanceFollowRedirects=false
        connection.connectTimeout=15000;connection.readTimeout=15000
        connection.requestMethod="POST";connection.doOutput=true
        connection.setRequestProperty("Content-Type","application/json")
        if(token!=null)connection.setRequestProperty("Authorization","Bearer "+token)
        val bytes=body.toString().toByteArray()
        connection.setFixedLengthStreamingMode(bytes.size)
        connection.outputStream.use { it.write(bytes) }
        if(connection.responseCode!=200) throw NativeLoginException(connection.responseCode)
        return JSONObject(String(connection.inputStream.use { it.readBytesLimited(65536) },Charsets.UTF_8))
    } finally { connection.disconnect() }
}
