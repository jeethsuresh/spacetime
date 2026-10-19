package com.jeethsuresh.spacetime

import android.Manifest
import android.app.*
import android.content.*
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.util.AtomicFile
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/** Atomic app-private calendar storage; no server or account required. */
object CalendarDisk {
    @Synchronized fun read(context: Context): String? {
        val file = AtomicFile(File(context.filesDir,"calendar.json"))
        return try { file.openRead().use { it.readBytes().toString(Charsets.UTF_8) } }
            catch (_: java.io.FileNotFoundException) { null }
    }
    @Synchronized fun write(context: Context, value: String) {
        JSONObject(value) // reject a truncated/invalid snapshot before touching disk
        val file = AtomicFile(File(context.filesDir,"calendar.json"))
        val output = file.startWrite()
        try { output.write(value.toByteArray(Charsets.UTF_8)); file.finishWrite(output) }
        catch(e: Exception) { file.failWrite(output); throw e }
    }
}

object LocalReminders {
    private const val channel = "event_reminders"
    private const val alarmAction = "com.jeethsuresh.spacetime.REMIND"
    private fun manager(c:Context) = c.getSystemService(AlarmManager::class.java)
    private fun pending(c:Context,id:String) = PendingIntent.getBroadcast(c,0,
        Intent(c,ReminderReceiver::class.java).setAction(alarmAction).setData(Uri.parse("spacetime://reminder/$id")).putExtra("id",id),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    fun allowed(c:Context):Boolean = (Build.VERSION.SDK_INT < 33 || c.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) &&
        c.getSystemService(NotificationManager::class.java).areNotificationsEnabled()
    fun configure(c:Context, enabled:Boolean, events:List<*>) {
        val prefs=c.getSharedPreferences("spacetime.reminders",Context.MODE_PRIVATE)
        val old=JSONArray(prefs.getString("events","[]"))
        for(i in 0 until old.length()) manager(c).cancel(pending(c,old.getJSONObject(i).getString("id")))
        val array=JSONArray()
        for(event in events) array.put(JSONObject(event as Map<*,*>))
        check(prefs.edit().putBoolean("enabled",enabled).putString("events",array.toString()).commit())
        restore(c)
    }
    fun restore(c:Context) {
        val prefs=c.getSharedPreferences("spacetime.reminders",Context.MODE_PRIVATE)
        if(!prefs.getBoolean("enabled",false)) return
        val events=JSONArray(prefs.getString("events","[]"))
        for(i in 0 until events.length()) schedule(c,events.getJSONObject(i))
    }
    fun schedule(c:Context,event:JSONObject, after:Long=System.currentTimeMillis()) {
        val intent=pending(c,event.getString("id"))
        manager(c).cancel(intent)
        if(!allowed(c)) return
        val next=ReminderSchedule.next(event,after) ?: return
        check(c.getSharedPreferences("spacetime.reminders",Context.MODE_PRIVATE).edit().putString("due.${event.getString("id")}",JSONObject().put("at",next.at).put("title",next.title).toString()).commit())
        // Only the next occurrence is registered. The alarm receiver advances the
        // same local schedule when it fires, including indefinitely recurring rules.
        if(Build.VERSION.SDK_INT < 31 || manager(c).canScheduleExactAlarms())
            manager(c).setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP,next.at,intent)
        else manager(c).setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP,next.at,intent)
    }
    fun deliver(c:Context,id:String) {
        val prefs=c.getSharedPreferences("spacetime.reminders",Context.MODE_PRIVATE)
        if(!prefs.getBoolean("enabled",false)) return
        val events=JSONArray(prefs.getString("events","[]"))
        val event=(0 until events.length()).map { events.getJSONObject(it) }.firstOrNull { it.getString("id")==id } ?: return
        if(allowed(c)) {
            val manager=c.getSystemService(NotificationManager::class.java)
            if(Build.VERSION.SDK_INT >= 26) manager.createNotificationChannel(NotificationChannel(channel,"Event reminders",NotificationManager.IMPORTANCE_DEFAULT))
            val open=PendingIntent.getActivity(c,0,Intent(c,MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            val builder=if(Build.VERSION.SDK_INT >= 26) Notification.Builder(c,channel) else @Suppress("DEPRECATION") Notification.Builder(c)
            val due=JSONObject(prefs.getString("due.$id","{}") ?: "{}")
            val notification=builder.setSmallIcon(R.drawable.ic_notification).setContentTitle(due.optString("title",event.getString("title")))
                .setContentText(if(event.optString("kind")=="todo") "Todo reminder" else "Event reminder")
                .setContentIntent(open).setAutoCancel(true).setCategory(Notification.CATEGORY_EVENT)
                .setVisibility(Notification.VISIBILITY_PRIVATE).build()
            manager.notify(id,0,notification)
        }
        schedule(c,event)
    }
    fun diagnostics(c:Context):Map<String,Any> {
        val prefs=c.getSharedPreferences("spacetime.reminders",Context.MODE_PRIVATE)
        val events=JSONArray(prefs.getString("events","[]"))
        return mapOf("enabled" to prefs.getBoolean("enabled",false),"allowed" to allowed(c),"events" to events.length(),
            "notifications" to c.getSystemService(NotificationManager::class.java).activeNotifications.map { it.notification.extras.getString(Notification.EXTRA_TITLE) ?: "" },
            "next" to (if(events.length()>0) ReminderSchedule.next(events.getJSONObject(0),System.currentTimeMillis())?.at ?: 0L else 0L))
    }
}

class ReminderReceiver:BroadcastReceiver() {
    override fun onReceive(context:Context,intent:Intent) {
        // Alarm delivery and OS clock/boot changes are the only wakeups. There is
        // no service, timer, worker, push registration, analytics or network call.
        try {
            if(intent.action=="com.jeethsuresh.spacetime.REMIND") intent.getStringExtra("id")?.let { LocalReminders.deliver(context,it) }
            else LocalReminders.restore(context)
        } catch(e:Exception) { android.util.Log.e("Spacetime","Could not restore a local reminder",e) }
    }
}
