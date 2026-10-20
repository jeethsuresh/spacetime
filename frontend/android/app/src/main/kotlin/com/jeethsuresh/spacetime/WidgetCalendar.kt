package com.jeethsuresh.spacetime

import org.json.JSONObject
import java.time.*

/** Widget projections share the exact recurrence/exception engine used by alarms. */
object WidgetCalendar {
    data class Snapshot(val next:ReminderSchedule.Next?,val days:List<List<ReminderSchedule.Next>>,val nextChange:Long)
    fun records(snapshot:JSONObject,showInvites:Boolean):List<JSONObject> {
        val entries=snapshot.optJSONArray("entries") ?: org.json.JSONArray()
        val username=snapshot.optJSONObject("user")?.optString("username","local") ?: "local"
        val items=(0 until entries.length()).map { entries.getJSONObject(it) }.filter {
            val owner=it.optString("owner","local")
            val invited=it.optBoolean("_invitation") || (it.has("_editable") && !it.optBoolean("_editable")) ||
                (owner!="local" && owner!=username && !it.optBoolean("_editable"))
            showInvites || !invited
        }.toMutableList()
        val invites=snapshot.optJSONArray("invitations") ?: org.json.JSONArray()
        if(showInvites) for(i in 0 until invites.length()) {
            val e=invites.getJSONObject(i)
            if(e.optString("_response")=="declined") continue
            if(items.none { (it.optString("_remote_id").ifEmpty { it.optString("id") })==e.optString("id") &&
                (it.isNull("_account") || it.optString("_account")==e.optString("_account")) }) items.add(e)
        }
        return items
    }
    fun project(snapshot:JSONObject,showInvites:Boolean,now:Long,zone:ZoneId=ZoneId.systemDefault()):Snapshot {
        val today=Instant.ofEpochMilli(now).atZone(zone).toLocalDate()
        val days=List(7) { mutableListOf<ReminderSchedule.Next>() }
        var appointment:ReminderSchedule.Next?=null
        var nextChange=today.plusDays(1).atStartOfDay(zone).toInstant().toEpochMilli()
        for(raw in records(snapshot,showInvites)) {
            if(raw.optBoolean("completed") || raw.optBoolean("_cancelled")) continue
            val e=JSONObject(raw.toString())
            try {
                val eventZone=CalendarNativeZone(e,zone)
                for(field in listOf("start","end","due")) if(e.optString("${field}_local").isEmpty() && e.has(field)) {
                    val instant=Instant.parse(e.getString(field))
                    e.put("${field}_local",if(e.optBoolean("all_day")) instant.atOffset(ZoneOffset.UTC).toLocalDate().toString() else eventZone.wall(instant).toString())
                }
                if(e.optString("start_local").isEmpty() && e.optString("due_local").isEmpty()) continue
                if(e.optString("kind","event")=="event") {
                    val upcoming=ReminderSchedule.next(e,now,zone,calendar=true)
                    if(upcoming!=null && (appointment==null || upcoming.occurrence<appointment!!.occurrence)) appointment=upcoming
                }
                for(day in 0..6) {
                    val a=today.plusDays(day.toLong()).atStartOfDay(zone).toInstant().toEpochMilli()
                    val b=today.plusDays(day+1L).atStartOfDay(zone).toInstant().toEpochMilli()
                    var cursor:Long?=null
                    // Four rows per source/day establish the compact display and
                    // its overflow affordance without losing later days' markers.
                    for(n in 0 until 4) {
                        val occurrence=ReminderSchedule.next(e,a-1,zone,calendar=true,afterStart=cursor) ?: break
                        cursor=occurrence.occurrence
                        if(occurrence.occurrence>=b) break
                        if(occurrence.end>a) days[day].add(occurrence)
                        if(occurrence.occurrence>now) nextChange=kotlin.math.min(nextChange,occurrence.occurrence)
                        if(occurrence.end>now) nextChange=kotlin.math.min(nextChange,occurrence.end)
                    }
                }
            } catch(ex:Exception) { android.util.Log.w("Spacetime","Could not project widget event",ex) }
        }
        if(appointment!=null) {
            if(appointment!!.occurrence>now) nextChange=kotlin.math.min(nextChange,appointment!!.occurrence)
            if(appointment!!.end>now) nextChange=kotlin.math.min(nextChange,appointment!!.end)
        }
        for(day in days) day.sortWith(compareBy<ReminderSchedule.Next>({!it.allDay},{it.occurrence},{it.title}))
        return Snapshot(appointment,days,nextChange)
    }
}
