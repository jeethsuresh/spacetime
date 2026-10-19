package com.jeethsuresh.spacetime

import org.dmfs.rfc5545.DateTime as RfcDate
import org.dmfs.rfc5545.recur.RecurrenceRule
import org.json.JSONObject
import java.time.*
import java.time.format.DateTimeFormatter
import java.util.TimeZone

/** Honors an embedded VTIMEZONE before consulting the device's IANA database. */
class CalendarNativeZone(event:JSONObject, deviceZone:ZoneId) {
    private val name=event.optString("timezone","UTC")
    private val observations=if(event.optBoolean("all_day") || name=="floating") null
        else event.optJSONObject("_timezones")?.optJSONArray(name)
    private val location=if(observations!=null) null else if(event.optBoolean("all_day") || name=="floating") deviceZone else ZoneId.of(name)
    private data class Transition(val at:Instant,val before:Int,val after:Int)
    private val cache=mutableMapOf<Int,List<Transition>>()
    private fun transitions(year:Int):List<Transition> = cache.getOrPut(year) {
        val result=mutableListOf<Transition>()
        for(i in 0 until observations!!.length()) {
            val o=observations.getJSONObject(i)
            val first=ReminderSchedule.wall(o.getString("start"))
            val from=o.getInt("from");val to=o.getInt("to")
            val dates=mutableSetOf(first)
            val rdates=o.getJSONArray("rdates")
            for(n in 0 until rdates.length()) dates.add(ReminderSchedule.wall(rdates.getString(n)))
            val rule=o.getString("rrule")
            if(rule.isNotEmpty()) {
                val until=rule.split(';').firstOrNull { it.startsWith("UNTIL=") }?.substringAfter('=')?.let { ReminderSchedule.wall(it).toInstant(ZoneOffset.UTC) }
                val stripped=rule.split(';').filter { !it.startsWith("UNTIL=") }.joinToString(";")
                val it=RecurrenceRule(stripped).iterator(RfcDate(TimeZone.getTimeZone("UTC"),first.toInstant(ZoneOffset.UTC).toEpochMilli()))
                while(it.hasNext()) {
                    val w=LocalDateTime.ofInstant(Instant.ofEpochMilli(it.nextMillis()),ZoneOffset.UTC)
                    if(w.year>year+1 || until!=null && w.toInstant(ZoneOffset.UTC).minusSeconds(from.toLong())>until) break
                    dates.add(w)
                }
            }
            for(w in dates) result.add(Transition(w.toInstant(ZoneOffset.UTC).minusSeconds(from.toLong()),from,to))
        }
        result.sortedBy { it.at }
    }
    fun wall(instant:Instant):LocalDateTime {
        if(location!=null) return LocalDateTime.ofInstant(instant,location)
        val transitions=transitions(instant.atOffset(ZoneOffset.UTC).year)
        val offset=transitions.lastOrNull { it.at<=instant }?.after ?: transitions.first().before
        return LocalDateTime.ofInstant(instant.plusSeconds(offset.toLong()),ZoneOffset.UTC)
    }
    fun resolve(value:LocalDateTime,generated:Boolean):Instant? {
        if(location!=null) {
            val offsets=location.rules.getValidOffsets(value)
            if(offsets.isNotEmpty()) return value.toInstant(offsets[0])
            return if(generated) null else value.toInstant(location.rules.getTransition(value).offsetBefore)
        }
        val transitions=transitions(value.year)
        val offsets=transitions.flatMap { listOf(it.before,it.after) }.toSet()
        val candidates=offsets.map { value.toInstant(ZoneOffset.UTC).minusSeconds(it.toLong()) }.filter { wall(it)==value }
        if(candidates.isNotEmpty()) return candidates.minOrNull()
        if(generated) return null
        for(t in transitions) {
            val first=LocalDateTime.ofInstant(t.at.plusSeconds(t.before.toLong()),ZoneOffset.UTC)
            val last=LocalDateTime.ofInstant(t.at.plusSeconds(t.after.toLong()),ZoneOffset.UTC)
            if(value>=first && value<last) return value.toInstant(ZoneOffset.UTC).minusSeconds(t.before.toLong())
        }
        throw IllegalArgumentException("Cannot resolve embedded time zone $name")
    }
}
