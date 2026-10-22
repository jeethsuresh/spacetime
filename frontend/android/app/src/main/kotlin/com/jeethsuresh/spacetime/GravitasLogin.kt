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
    fun begin(register:Boolean):Intent {
        val verifier=random();val state=random()
        vaultWrite(PENDING,JSONObject().put("verifier",verifier).put("state",state).put("expires",System.currentTimeMillis()+600000).toString())
        vaultWrite(RESULT,null)
        val challenge=Base64.encodeToString(MessageDigest.getInstance("SHA-256").digest(verifier.toByteArray(Charsets.US_ASCII)),Base64.NO_WRAP or Base64.URL_SAFE or Base64.NO_PADDING)
        val uri=Uri.parse("$ORIGIN/auth/gravitas/start").buildUpon().appendQueryParameter("native_challenge",challenge).appendQueryParameter("native_state",state)
        if(register) uri.appendQueryParameter("screen","register")
        return Intent(Intent.ACTION_VIEW,uri.build()).addCategory(Intent.CATEGORY_BROWSABLE)
    }
    fun callback(uri:Uri):String? {
        if(!isCallback(uri)) return null
        val pending=vaultRead(PENDING)?.let { JSONObject(it) } ?: return null
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
                val token=response.getString("token")
                check(token.matches(Regex("^[a-f0-9]{48}$")) && response.getJSONObject("user").getString("username").isNotEmpty())
                vaultWrite("$ORIGIN/user",response.getJSONObject("user").toString())
                vaultWrite(ORIGIN,token)
                result="connected"
            }
        } catch(_:Exception) { result="failed" }
        vaultWrite(RESULT,result)
        return result
    }
    fun takeResult():String? = vaultRead(RESULT)?.also { vaultWrite(RESULT,null) }
    fun failed() { vaultWrite(PENDING,null);vaultWrite(RESULT,"failed") }
}

private fun java.io.InputStream.readBytesLimited(limit:Int):ByteArray {
    val output=java.io.ByteArrayOutputStream()
    val buffer=ByteArray(4096)
    while(true) { val count=read(buffer);if(count<0)break;check(output.size()+count<=limit);output.write(buffer,0,count) }
    return output.toByteArray()
}

private fun exchangeNative(code:String, verifier:String):JSONObject {
    val connection=URL("${GravitasLogin.ORIGIN}/api/auth/gravitas/android").openConnection() as HttpsURLConnection
    try {
        connection.instanceFollowRedirects=false
        connection.connectTimeout=15000;connection.readTimeout=15000
        connection.requestMethod="POST";connection.doOutput=true
        connection.setRequestProperty("Content-Type","application/json")
        val body=JSONObject().put("code",code).put("code_verifier",verifier).toString().toByteArray()
        connection.setFixedLengthStreamingMode(body.size)
        connection.outputStream.use { it.write(body) }
        check(connection.responseCode==200)
        return JSONObject(String(connection.inputStream.use { it.readBytesLimited(65536) },Charsets.UTF_8))
    } finally { connection.disconnect() }
}
