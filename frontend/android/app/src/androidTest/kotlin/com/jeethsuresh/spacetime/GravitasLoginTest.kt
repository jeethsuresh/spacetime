package com.jeethsuresh.spacetime

import android.net.Uri
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.security.MessageDigest
import android.util.Base64

class GravitasLoginTest {
    private val context=InstrumentationRegistry.getInstrumentation().targetContext
    private val vault=mutableMapOf<String,String>()
    private fun login()=GravitasLogin(context,{vault[it]},{k,v -> if(v==null) vault.remove(k) else vault[k]=v})
    @Test fun browserRequestUsesS256AndTransactionSurvivesRecreation() {
        val request=login().begin(false).data!!
        assertEquals(GravitasLogin.ORIGIN,request.scheme+"://"+request.host)
        val pending=JSONObject(vault[GravitasLogin.PENDING]!!)
        val verifier=pending.getString("verifier")
        assertEquals(43,verifier.length)
        val challenge=Base64.encodeToString(MessageDigest.getInstance("SHA-256").digest(verifier.toByteArray()),Base64.NO_WRAP or Base64.URL_SAFE or Base64.NO_PADDING)
        assertEquals(challenge,request.getQueryParameter("native_challenge"))
        assertEquals(pending.getString("state"),request.getQueryParameter("native_state"))
        val callback=Uri.parse("cool.gravitas.spacetime:/auth/callback?result=access_denied&state="+pending.getString("state"))
        assertEquals("access_denied",login().callback(callback))
        assertNull(vault[GravitasLogin.PENDING])
        assertEquals("access_denied",login().takeResult());assertNull(login().takeResult())
        assertNull(login().callback(callback))
    }
    @Test fun forgedCallbacksDoNotConsumePendingLogin() {
        val request=login().begin(true).data!!
        assertEquals("register",request.getQueryParameter("screen"))
        val state=request.getQueryParameter("native_state")!!
        for(uri in listOf("cool.gravitas.spacetime:/auth/callback?result=connected&state=forged", "cool.gravitas.spacetime:/auth/callback?result=connected&state=$state&state=$state", "cool.gravitas.spacetime://host/auth/callback?result=connected&state=$state", "cool.gravitas.spacetime:/other?state=$state")) {
            assertNull(login().callback(Uri.parse(uri)))
            assertNotNull(vault[GravitasLogin.PENDING])
        }
    }
    @Test fun expiredCallbacksNeverExchangeOrSaveSession() {
        val request=login().begin(false).data!!
        val pending=JSONObject(vault[GravitasLogin.PENDING]!!).put("expires",0)
        vault[GravitasLogin.PENDING]=pending.toString()
        assertEquals("failed",login().callback(Uri.parse("cool.gravitas.spacetime:/auth/callback?result=connected&code="+"a".repeat(48)+"&state="+request.getQueryParameter("native_state"))))
        assertNull(vault[GravitasLogin.ORIGIN])
    }
    @Test fun validCallbackExchangesWithSavedVerifierAndStoresAccount() {
        val request=login().begin(false).data!!
        val verifier=JSONObject(vault[GravitasLogin.PENDING]!!).getString("verifier")
        val code="c".repeat(48);val token="a".repeat(48)
        var calls=0
        val app=GravitasLogin(context,{vault[it]},{k,v -> if(v==null)vault.remove(k) else vault[k]=v},{receivedCode,receivedVerifier ->
            assertEquals(code,receivedCode);assertEquals(verifier,receivedVerifier);calls++
            JSONObject().put("token",token).put("user",JSONObject().put("username","native"))
        })
        val callback=Uri.parse("cool.gravitas.spacetime:/auth/callback?result=connected&code=$code&state="+request.getQueryParameter("native_state"))
        assertEquals("connected",app.callback(callback));assertEquals(token,vault[GravitasLogin.ORIGIN]);assertEquals(1,calls)
        assertNull(app.callback(callback));assertEquals(1,calls)
    }
}
