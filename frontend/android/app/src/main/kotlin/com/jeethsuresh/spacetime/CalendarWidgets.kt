package com.jeethsuresh.spacetime

import android.app.*
import android.appwidget.*
import android.content.*
import android.net.Uri
import android.os.Bundle
import android.widget.RemoteViews
import org.json.JSONObject
import java.time.*
import java.time.format.DateTimeFormatter
import java.util.concurrent.Executors

object CalendarWidgets {
    private val providers=listOf(NextAppointmentWidget::class.java,DayCalendarWidget::class.java,WeekCalendarWidget::class.java)
    private val worker=Executors.newSingleThreadExecutor()
    fun asynchronously(receiver:BroadcastReceiver,context:Context) {
        val pending=receiver.goAsync()
        worker.execute { try { update(context.applicationContext) } finally { pending.finish() } }
    }
    fun refresh(context:Context) {
        worker.execute { update(context.applicationContext) }
    }
    private fun update(context:Context) {
        try {
            val manager=AppWidgetManager.getInstance(context)
            val ids=providers.associateWith { manager.getAppWidgetIds(ComponentName(context,it)) }
            val alarm=context.getSystemService(AlarmManager::class.java)
            val refreshIntent=PendingIntent.getBroadcast(context,0,Intent(context,WidgetRefreshReceiver::class.java),PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            alarm.cancel(refreshIntent)
            if(ids.values.all { it.isEmpty() }) return
            val preferences=context.getSharedPreferences("spacetime.preferences",Context.MODE_PRIVATE)
                .getString("spacetime.preferences.device","{}") ?: "{}"
            val prefs=JSONObject(preferences)
            val snapshot=JSONObject(CalendarDisk.read(context) ?: "{}")
            val now=System.currentTimeMillis()
            val projection=WidgetCalendar.project(snapshot,prefs.optBoolean("show_invites",true),now)
            for((provider,widgets) in ids) for(id in widgets) {
                val height=manager.getAppWidgetOptions(id).getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT,174)
                manager.updateAppWidget(id,views(context,provider,id,projection,prefs.optBoolean("use_24_hour",true),height))
            }
            // One non-wakeup boundary alarm keeps visible widgets current at
            // midnight and event boundaries. No polling, network, worker job or service.
            alarm.set(AlarmManager.RTC,kotlin.math.max(now+1000,projection.nextChange),refreshIntent)
        } catch(e:Exception) { android.util.Log.e("Spacetime","Could not update calendar widgets",e) }
    }
    private fun open(c:Context,id:Int,date:LocalDate,view:String="Daily")=PendingIntent.getActivity(c,id,
        Intent(c,MainActivity::class.java).setData(Uri.parse("spacetime://calendar?date=$date&view=$view"))
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP),PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    private fun color(kind:String)=android.graphics.Color.parseColor(when(kind){"todo"->"#B78C3C";"occasion"->"#B67888";else->"#587F65"})
    private fun time(d:ReminderSchedule.Next,clock:Boolean):String = if(d.allDay) "All day" else
        Instant.ofEpochMilli(d.occurrence).atZone(ZoneId.systemDefault()).format(DateTimeFormatter.ofPattern(if(clock) "HH:mm" else "h:mm a"))
    internal fun views(c:Context,provider:Class<*>,id:Int,data:WidgetCalendar.Snapshot,clock:Boolean,height:Int=174):RemoteViews {
        val today=LocalDate.now()
        val mode=when(provider){NextAppointmentWidget::class.java->0;DayCalendarWidget::class.java->1;else->2}
        val layout=when(mode){0->R.layout.widget_next;1->R.layout.widget_day;else->R.layout.widget_week}
        val result=RemoteViews(c.packageName,layout)
        result.setOnClickPendingIntent(R.id.widget_root,open(c,id,today,if(mode==2) "Weekly" else "Daily"))
        if(mode==0) {
            val next=data.next
            result.setTextViewText(R.id.widget_heading,"Next")
            result.setTextViewText(R.id.widget_title,next?.title ?: "No upcoming appointments")
            result.setTextViewText(R.id.widget_time,next?.let { time(it,clock) } ?: "")
            val date=next?.let { Instant.ofEpochMilli(it.occurrence).atZone(ZoneId.systemDefault()).toLocalDate() }
            result.setTextViewText(R.id.widget_date,date?.format(DateTimeFormatter.ofPattern("EEE\nd MMM")) ?: "")
            if(date!=null) result.setOnClickPendingIntent(R.id.widget_root,open(c,id,date))
        } else if(mode==1) {
            result.setTextViewText(R.id.widget_heading,today.format(DateTimeFormatter.ofPattern("EEE, d MMM")))
            result.removeAllViews(R.id.widget_items)
            val scale=c.resources.configuration.fontScale
            val rows=((height-20-32*scale)/(5+29*scale)).toInt().coerceIn(1,3)
            for(event in data.days[0].take(rows)) {
                val row=RemoteViews(c.packageName,R.layout.widget_event_row)
                row.setTextViewText(R.id.widget_row_title,event.title)
                row.setTextViewText(R.id.widget_row_time,time(event,clock))
                row.setTextColor(R.id.widget_row_time,color(event.kind))
                row.setOnClickPendingIntent(R.id.widget_row,open(c,id,today))
                result.addView(R.id.widget_items,row)
            }
            result.setTextViewText(R.id.widget_empty,if(data.days[0].isEmpty()) "No events today" else if(data.days[0].size>rows) "Open calendar for more" else "")
        } else {
            result.setTextViewText(R.id.widget_heading,"${today.format(DateTimeFormatter.ofPattern("d MMM"))} – ${today.plusDays(6).format(DateTimeFormatter.ofPattern("d MMM"))}")
            result.removeAllViews(R.id.widget_days)
            for(i in 0..6) {
                val date=today.plusDays(i.toLong())
                val column=RemoteViews(c.packageName,R.layout.widget_week_day)
                column.setTextViewText(R.id.widget_week_label,date.format(DateTimeFormatter.ofPattern("EEEEE")))
                column.setTextViewText(R.id.widget_week_number,date.dayOfMonth.toString())
                column.setTextViewText(R.id.widget_week_dots,if(data.days[i].isEmpty()) "" else "●".repeat(kotlin.math.min(3,data.days[i].size)))
                column.setContentDescription(R.id.widget_week_column,date.format(DateTimeFormatter.ofPattern("EEEE d MMMM"))+if(data.days[i].isEmpty()) ", no events" else ", "+data.days[i].take(3).joinToString { it.title })
                column.setOnClickPendingIntent(R.id.widget_week_column,open(c,id,date))
                result.addView(R.id.widget_days,column)
            }
        }
        return result
    }
}
open class CalendarWidgetProvider:AppWidgetProvider() {
    override fun onUpdate(c:Context,m:AppWidgetManager,ids:IntArray){CalendarWidgets.asynchronously(this,c)}
    override fun onAppWidgetOptionsChanged(c:Context,m:AppWidgetManager,id:Int,options:Bundle){CalendarWidgets.asynchronously(this,c)}
    override fun onDisabled(c:Context){CalendarWidgets.asynchronously(this,c)}
}
class NextAppointmentWidget:CalendarWidgetProvider()
class DayCalendarWidget:CalendarWidgetProvider()
class WeekCalendarWidget:CalendarWidgetProvider()
class WidgetRefreshReceiver:BroadcastReceiver() {
    override fun onReceive(c:Context,intent:Intent){CalendarWidgets.asynchronously(this,c)}
}
