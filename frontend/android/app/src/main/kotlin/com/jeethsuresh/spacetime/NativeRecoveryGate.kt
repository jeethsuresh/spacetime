package com.jeethsuresh.spacetime

import org.json.JSONObject
import java.security.MessageDigest

internal enum class RecoveryDecision{START,SUPPRESS,BLOCKED}
/** Stored through the encrypted vault; no bearer appears in this record. */
internal class NativeRecoveryGate(private val read:()->String?,private val write:(String?)->Unit,private val now:()->Long={System.currentTimeMillis()}) {
    private fun key(token:String)=MessageDigest.getInstance("SHA-256").digest(token.toByteArray()).joinToString(""){"%02x".format(it)}
    private fun record(token:String,blocked:Boolean)=JSONObject().put("tokenHash",key(token)).put("at",now()).put("blocked",blocked).toString()
    fun begin(token:String):RecoveryDecision {
        val old=try{read()?.let{JSONObject(it)}}catch(_:Exception){null}
        if(old?.optString("tokenHash")==key(token)){
            if(old.optBoolean("blocked"))return RecoveryDecision.BLOCKED
            val age=now()-old.optLong("at")
            if(age>=0 && age<120000)return RecoveryDecision.SUPPRESS
        }
        write(record(token,false));return RecoveryDecision.START
    }
    fun finish(token:String,result:String){
        when(result){
            "connected"->write(null)
            "unavailable","canceled","suppressed"->write(record(token,false))
            else->write(record(token,true))
        }
    }
}
