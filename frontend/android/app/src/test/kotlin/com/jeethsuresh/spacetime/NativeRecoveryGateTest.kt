package com.jeethsuresh.spacetime

import org.junit.Assert.*
import org.junit.Test

class NativeRecoveryGateTest {
    @Test fun transientCooldownSurvivesNewInstanceAndEndsAfterTwoMinutes(){
        var stored:String?=null;var now=1000000L
        fun gate()=NativeRecoveryGate({stored},{stored=it},{now})
        assertEquals(RecoveryDecision.START,gate().begin("private-old-bearer"))
        assertFalse(stored!!.contains("private-old-bearer"))
        assertEquals(RecoveryDecision.SUPPRESS,gate().begin("private-old-bearer"))
        now+=10000;gate().finish("private-old-bearer","unavailable")
        now+=119999;assertEquals(RecoveryDecision.SUPPRESS,gate().begin("private-old-bearer"))
        now++;assertEquals(RecoveryDecision.START,gate().begin("private-old-bearer"))
    }
    @Test fun confirmedRevocationNeverResumesAndNewTokenIsIndependent(){
        var stored:String?=null;var now=1000000L
        fun gate()=NativeRecoveryGate({stored},{stored=it},{now})
        gate().begin("old");gate().finish("old","login_required");now+=99999999
        assertEquals(RecoveryDecision.BLOCKED,gate().begin("old"))
        assertEquals(RecoveryDecision.START,gate().begin("new"))
        gate().finish("new","connected");assertNull(stored)
    }
}
