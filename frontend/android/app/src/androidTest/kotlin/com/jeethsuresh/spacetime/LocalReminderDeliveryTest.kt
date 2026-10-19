package com.jeethsuresh.spacetime

import android.Manifest
import android.app.NotificationManager
import android.os.Build
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.rule.GrantPermissionRule
import org.junit.*
import org.junit.Assert.*
import org.junit.runner.RunWith
import java.time.Instant
import java.time.LocalDateTime
import java.time.ZoneOffset

@RunWith(AndroidJUnit4::class)
class LocalReminderDeliveryTest {
    @get:Rule val permission:GrantPermissionRule = if(Build.VERSION.SDK_INT>=33)
        GrantPermissionRule.grant(Manifest.permission.POST_NOTIFICATIONS) else GrantPermissionRule.grant()
    private val context get()=InstrumentationRegistry.getInstrumentation().targetContext.applicationContext
    @After fun cleanup() {
        LocalReminders.configure(context,false,emptyList<Any>())
        context.getSystemService(NotificationManager::class.java).cancelAll()
    }
    @Test fun alarmPostsWithoutFlutterOrNetworkAndRestoresFromLocalStorage() {
        val title="Offline alarm delivery test"
        val soon=LocalDateTime.ofInstant(Instant.now().plusSeconds(6),ZoneOffset.UTC).withNano(0).toString()
        val events=listOf(mapOf("id" to "delivery-test","title" to title,"kind" to "event","all_day" to false,
            "timezone" to "UTC","start_local" to soon,"rrule" to "","reminder_minutes" to 0))
        assertTrue(LocalReminders.allowed(context))
        LocalReminders.configure(context,true,events)
        LocalReminders.restore(context) // same path as OS boot/time-zone recovery
        Thread.sleep(8500)
        val posted=context.getSystemService(NotificationManager::class.java).activeNotifications
        assertTrue("The OS must deliver the local alarm notification",posted.any { it.notification.extras.getString(android.app.Notification.EXTRA_TITLE)==title })
    }
    @Test fun deletingTheReminderCancelsItsPendingAlarm() {
        val soon=LocalDateTime.ofInstant(Instant.now().plusSeconds(4),ZoneOffset.UTC).withNano(0).toString()
        LocalReminders.configure(context,true,listOf(mapOf("id" to "cancel-test","title" to "Cancelled reminder","kind" to "event",
            "all_day" to false,"timezone" to "UTC","start_local" to soon,"rrule" to "","reminder_minutes" to 0)))
        LocalReminders.configure(context,true,emptyList<Any>())
        Thread.sleep(6000)
        assertFalse(context.getSystemService(NotificationManager::class.java).activeNotifications.any { it.tag=="cancel-test" })
    }
}
