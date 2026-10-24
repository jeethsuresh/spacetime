package com.jeethsuresh.spacetime

import android.Manifest
import android.app.NotificationManager
import android.content.Context
import android.os.Build
import android.os.Bundle
import android.util.Base64
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.rule.GrantPermissionRule
import org.json.JSONObject
import org.junit.*
import org.junit.Assert.*
import org.junit.runner.RunWith
import java.security.MessageDigest

/** Run against the isolated .dev package on a disposable emulator. */
@RunWith(AndroidJUnit4::class)
class StoreNotificationDeliveryTest {
    @get:Rule val permission: GrantPermissionRule = if (Build.VERSION.SDK_INT >= 33) GrantPermissionRule.grant(Manifest.permission.POST_NOTIFICATIONS) else GrantPermissionRule.grant()
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext
    private val sessionKey get() = Base64.encodeToString(MessageDigest.getInstance("SHA-256").digest(GravitasLogin.ORIGIN.toByteArray()), Base64.NO_WRAP)
    private var original: String? = null
    @Before fun setup() {
        original = CalendarDisk.read(context)
        StoreNotifications.clear(context)
        context.getSharedPreferences("spacetime.sessions", Context.MODE_PRIVATE).edit().putString(sessionKey, "test-presence-only").commit()
        CalendarDisk.write(context, JSONObject().put("server", GravitasLogin.ORIGIN).put("user", JSONObject().put("username", "sam")).toString())
        context.getSharedPreferences("spacetime.preferences", Context.MODE_PRIVATE).edit().remove("spacetime.gravitas.disconnected").commit()
    }
    @After fun cleanup() {
        StoreNotifications.clear(context)
        context.getSharedPreferences("spacetime.sessions", Context.MODE_PRIVATE).edit().remove(sessionKey).commit()
        original?.let { CalendarDisk.write(context, it) }
    }
    private fun payload(version: Int = 1, username: String = "sam", kind: String = "event.invited") = JSONObject()
        .put("event_id", "a".repeat(48)).put("version", version).put("username", username)
        .put("kind", kind).put("title", "Dinner").put("start", "2026-10-25T18:00:00Z").toString()
    @Test fun nativeHandlerPostsWithoutStartingFlutterAndSuppressesReplay() {
        assertTrue(StoreNotificationDelivery.deliver(context, payload()).getBoolean("accepted"))
        val manager = context.getSystemService(NotificationManager::class.java)
        val first = manager.activeNotifications.single { it.tag?.startsWith("push:") == true }
        assertEquals("New invitation", first.notification.extras.getString(android.app.Notification.EXTRA_TITLE))
        StoreNotificationDelivery.deliver(context, payload(2, kind = "event.updated"))
        StoreNotificationDelivery.deliver(context, payload())
        val updated = manager.activeNotifications.single { it.tag == first.tag }
        assertEquals("Calendar update", updated.notification.extras.getString(android.app.Notification.EXTRA_TITLE))
        assertEquals(2, context.getSharedPreferences("spacetime.push", Context.MODE_PRIVATE).getInt("sam:${"a".repeat(48)}", 0))
    }
    @Test fun differentAccountAndSignedOutClientsCannotDisplayAlerts() {
        StoreNotificationDelivery.deliver(context, payload(username = "other"))
        context.getSharedPreferences("spacetime.sessions", Context.MODE_PRIVATE).edit().remove(sessionKey).commit()
        StoreNotificationDelivery.deliver(context, payload())
        assertFalse(context.getSystemService(NotificationManager::class.java).activeNotifications.any { it.tag?.startsWith("push:") == true })
    }
    @Test fun replacedSessionCannotUseAStaleNotificationIdentity() {
        context.getSharedPreferences("spacetime.sessions", Context.MODE_PRIVATE).edit().putString(sessionKey, "different-encrypted-session").commit()
        StoreNotificationDelivery.deliver(context, payload())
        assertFalse(context.getSystemService(NotificationManager::class.java).activeNotifications.any { it.tag?.startsWith("push:") == true })
    }
    @Test fun exportedProviderRejectsAnUntrustedBinderCaller() {
        val provider = StoreNotifications()
        provider.attachInfo(context, android.content.pm.ProviderInfo())
        try { provider.call("notify", null, Bundle().apply { putString("payload", payload()) }); fail("Unsigned IPC must fail") }
        catch (_: SecurityException) { }
    }
}
