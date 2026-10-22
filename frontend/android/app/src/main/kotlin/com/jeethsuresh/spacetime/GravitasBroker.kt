package com.jeethsuresh.spacetime

import android.accounts.Account
import android.accounts.AccountManager
import android.accounts.AuthenticatorException
import android.accounts.OperationCanceledException
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import java.io.IOException
import java.security.MessageDigest
import java.util.concurrent.TimeUnit

internal object BrokerProtocol {
    const val PACKAGE="dev.jeeth.privatestore"
    const val CERTIFICATE="e70b5b54a0d174f4ad8867889f6481a2b193dc9c130630f321563e12f3293793"
    const val ACCOUNT_TYPE="dev.jeeth.privatestore.gravitas"
    const val ISSUER="https://gravitas.cool"
    const val REDIRECT=GravitasLogin.ORIGIN+"/auth/gravitas/callback"
    fun tokenType(challenge:String,state:String):String {
        require(challenge.matches(Regex("^[A-Za-z0-9_-]{43}$")) && state.matches(Regex("^[A-Za-z0-9_-]{43}$")))
        return "gravitas_code:spacetime:v1:$challenge:$state"
    }
    fun trusted(packageName:String,accountType:String,signers:List<String>):Boolean =
        packageName==PACKAGE && accountType==ACCOUNT_TYPE && signers==listOf(CERTIFICATE)
}

internal data class BrokerCode(val code:String,val subject:String,val sessionId:String)
internal sealed class BrokerResult {
    data class Authorized(val value:BrokerCode):BrokerResult()
    object Browser:BrokerResult()
    object Unavailable:BrokerResult()
    object Canceled:BrokerResult()
}

internal interface BrokerPlatform {
    fun trusted():Boolean
    fun accounts():List<String>
    fun request(account:String,type:String,options:Bundle):Bundle
    fun invalidate(code:String)
}

/** Foreground-only, noninteractive AccountManager request. Never starts provider intents. */
internal class GravitasBroker(private val platform:BrokerPlatform) {
    constructor(context:Context):this(AndroidBrokerPlatform(context.applicationContext))
    fun authorize(challenge:String,state:String):BrokerResult {
        return try {
            val type=BrokerProtocol.tokenType(challenge,state)
            if(!platform.trusted()) return BrokerResult.Browser
            val accounts=platform.accounts()
            // Account selection remains explicit in the browser when ambiguous.
            if(accounts.size!=1) return BrokerResult.Browser
            val options=Bundle().apply{putInt("protocolVersion",1);putString("codeChallenge",challenge);putString("state",state)}
            val response=platform.request(accounts.single(),type,options)
            val code=response.getString(AccountManager.KEY_AUTHTOKEN)
            if(!code.isNullOrEmpty()) platform.invalidate(code)
            if(response.containsKey(AccountManager.KEY_INTENT)) return BrokerResult.Browser
            when(response.getInt(AccountManager.KEY_ERROR_CODE,0)) {
                AccountManager.ERROR_CODE_CANCELED -> return BrokerResult.Canceled
                AccountManager.ERROR_CODE_NETWORK_ERROR -> return BrokerResult.Unavailable
                AccountManager.ERROR_CODE_BAD_AUTHENTICATION,AccountManager.ERROR_CODE_UNSUPPORTED_OPERATION -> return BrokerResult.Browser
                0 -> {}
                else -> return BrokerResult.Unavailable
            }
            require(response.getInt("protocolVersion")==1 && response.getString("state")==state && response.getString("codeChallenge")==challenge)
            require(response.getString("issuer")==BrokerProtocol.ISSUER && response.getString("appOrigin")==GravitasLogin.ORIGIN && response.getString("redirectUri")==BrokerProtocol.REDIRECT)
            require(response.getString(AccountManager.KEY_ACCOUNT_TYPE)==BrokerProtocol.ACCOUNT_TYPE && response.getString(AccountManager.KEY_ACCOUNT_NAME)==accounts.single())
            require(!code.isNullOrEmpty() && code.length<=4096)
            val subject=response.getString("subject") ?: error("missing subject")
            val session=response.getString("sessionId") ?: error("missing family")
            require(subject.isNotEmpty() && subject.length<=200 && session.isNotEmpty() && session.length<=200)
            BrokerResult.Authorized(BrokerCode(code,subject,session))
        } catch(_:OperationCanceledException) { BrokerResult.Canceled }
          catch(_:IOException) { BrokerResult.Unavailable }
          catch(_:AuthenticatorException) { BrokerResult.Browser }
          catch(_:SecurityException) { BrokerResult.Browser }
          catch(_:Exception) { BrokerResult.Unavailable }
    }
}

private class AndroidBrokerPlatform(private val context:Context):BrokerPlatform {
    private val accounts=AccountManager.get(context)
    override fun trusted():Boolean {
        if(Build.VERSION.SDK_INT<26) return false
        val manager=context.packageManager
        val flags=if(Build.VERSION.SDK_INT>=28) PackageManager.GET_SIGNING_CERTIFICATES else @Suppress("DEPRECATION") PackageManager.GET_SIGNATURES
        val info=try{manager.getPackageInfo(BrokerProtocol.PACKAGE,flags)}catch(_:PackageManager.NameNotFoundException){return false}
        if(info.applicationInfo?.enabled!=true) return false
        val signatures=if(Build.VERSION.SDK_INT>=28) info.signingInfo?.apkContentsSigners else @Suppress("DEPRECATION") info.signatures
        val digests=signatures?.map{signature->MessageDigest.getInstance("SHA-256").digest(signature.toByteArray()).joinToString(""){"%02x".format(it)}} ?: return false
        val authenticators=accounts.authenticatorTypes.filter{it.type==BrokerProtocol.ACCOUNT_TYPE}
        return authenticators.size==1 && BrokerProtocol.trusted(authenticators.single().packageName,authenticators.single().type,digests)
    }
    override fun accounts():List<String> = accounts.getAccountsByType(BrokerProtocol.ACCOUNT_TYPE).map{it.name}
    override fun request(account:String,type:String,options:Bundle):Bundle {
        val pending=accounts.getAuthToken(Account(account,BrokerProtocol.ACCOUNT_TYPE),type,options,false,null,null)
        return try{pending.getResult(20,TimeUnit.SECONDS)}finally{if(!pending.isDone)pending.cancel(true)}
    }
    override fun invalidate(code:String){accounts.invalidateAuthToken(BrokerProtocol.ACCOUNT_TYPE,code)}
}
