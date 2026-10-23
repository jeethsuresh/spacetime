package com.jeethsuresh.spacetime

import android.accounts.AccountManager
import android.os.Bundle
import org.junit.Assert.*
import org.junit.Test

class GravitasBrokerTest {
    private val challenge="c".repeat(43);private val state="s".repeat(43)
    private class Platform:BrokerPlatform {
        var trusted=true;var available=true;var prepares=0;var names=listOf("test-account");var calls=0;var invalidated:String?=null
        var response=Bundle()
        override fun trusted()=trusted
        override fun prepare():Boolean{prepares++;return available}
        override fun accounts()=names
        override fun request(account:String,type:String,options:Bundle):Bundle {calls++;assertEquals("gravitas_code:spacetime:v1:${options.getString("codeChallenge")}:${options.getString("state")}",type);return response}
        override fun invalidate(code:String){invalidated=code}
    }
    private fun response()=Bundle().apply{
        putString(AccountManager.KEY_AUTHTOKEN,"one-use-code");putString(AccountManager.KEY_ACCOUNT_NAME,"test-account");putString(AccountManager.KEY_ACCOUNT_TYPE,BrokerProtocol.ACCOUNT_TYPE)
        putInt("protocolVersion",1);putString("state",state);putString("codeChallenge",challenge);putString("issuer",BrokerProtocol.ISSUER);putString("appOrigin",GravitasLogin.ORIGIN);putString("redirectUri",BrokerProtocol.REDIRECT);putString("sessionId","test-family");putString("subject","test-subject")
    }
    @Test fun accountCacheKeyAndResponseBindEveryRequest(){
        val platform=Platform();platform.response=response()
        val result=GravitasBroker(platform).authorize(challenge,state) as BrokerResult.Authorized
        assertEquals("one-use-code",result.value.code);assertEquals("test-family",result.value.sessionId);assertEquals("test-subject",result.value.subject)
        assertEquals("one-use-code",platform.invalidated);assertEquals(1,platform.calls)
        assertNotEquals(BrokerProtocol.tokenType(challenge,state),BrokerProtocol.tokenType(challenge,"n".repeat(43)))
        assertNotEquals(BrokerProtocol.tokenType(challenge,state),BrokerProtocol.tokenType("n".repeat(43),state))
    }
    @Test fun forgedOrCachedBindingsAreRejected(){
        for(key in listOf("state","codeChallenge","issuer","appOrigin","redirectUri",AccountManager.KEY_ACCOUNT_NAME,AccountManager.KEY_ACCOUNT_TYPE,"sessionId","subject")){
            val platform=Platform();platform.response=response().apply{putString(key,if(key=="sessionId"||key=="subject")"" else "forged")}
            assertSame(key,BrokerResult.Unavailable,GravitasBroker(platform).authorize(challenge,state));assertEquals("one-use-code",platform.invalidated)
        }
    }
    @Test fun unavailableProviderAndAmbiguousAccountsUseBrowserWithoutRequests(){
        for(names in listOf(emptyList(),listOf("one","two"))){val platform=Platform();platform.names=names;assertSame(BrokerResult.Browser,GravitasBroker(platform).authorize(challenge,state));assertEquals(0,platform.calls)}
        val platform=Platform();platform.trusted=false;assertSame(BrokerResult.Browser,GravitasBroker(platform).authorize(challenge,state));assertEquals(0,platform.calls);assertEquals(0,platform.prepares)
        val unavailable=Platform();unavailable.available=false;assertSame(BrokerResult.Browser,GravitasBroker(unavailable).authorize(challenge,state));assertEquals(1,unavailable.prepares);assertEquals(0,unavailable.calls)
    }
    @Test fun networkAndCancellationDoNotOpenBrowser(){
        for((code,result) in listOf(AccountManager.ERROR_CODE_CANCELED to BrokerResult.Canceled,AccountManager.ERROR_CODE_NETWORK_ERROR to BrokerResult.Unavailable,AccountManager.ERROR_CODE_BAD_AUTHENTICATION to BrokerResult.Browser,AccountManager.ERROR_CODE_UNSUPPORTED_OPERATION to BrokerResult.Browser)){
            val platform=Platform();platform.response=Bundle().apply{putInt(AccountManager.KEY_ERROR_CODE,code)}
            assertSame(result,GravitasBroker(platform).authorize(challenge,state))
        }
    }
    @Test fun exactPackageTypeAndSinglePermanentCertificateAreRequired(){
        assertTrue(BrokerProtocol.trusted(BrokerProtocol.PACKAGE,BrokerProtocol.ACCOUNT_TYPE,listOf(BrokerProtocol.CERTIFICATE)))
        assertFalse(BrokerProtocol.trusted("attacker",BrokerProtocol.ACCOUNT_TYPE,listOf(BrokerProtocol.CERTIFICATE)))
        assertFalse(BrokerProtocol.trusted(BrokerProtocol.PACKAGE,"attacker",listOf(BrokerProtocol.CERTIFICATE)))
        assertFalse(BrokerProtocol.trusted(BrokerProtocol.PACKAGE,BrokerProtocol.ACCOUNT_TYPE,listOf("wrong")))
        assertFalse(BrokerProtocol.trusted(BrokerProtocol.PACKAGE,BrokerProtocol.ACCOUNT_TYPE,listOf(BrokerProtocol.CERTIFICATE,"extra")))
    }
}
