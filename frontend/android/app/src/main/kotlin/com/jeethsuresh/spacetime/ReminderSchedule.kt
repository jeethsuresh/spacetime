package com.jeethsuresh.spacetime

import org.dmfs.rfc5545.DateTime as RfcDate
import org.dmfs.rfc5545.recur.RecurrenceRule
import org.json.JSONObject
import java.time.*
import java.time.format.DateTimeFormatter
import java.time.temporal.WeekFields
import java.util.TimeZone

/** Pure local recurrence calculation; never accesses the network. */
object ReminderSchedule {
    private val compact = DateTimeFormatter.ofPattern("yyyyMMdd'T'HHmmss")
    private val dateCompact = DateTimeFormatter.BASIC_ISO_DATE
    data class Next(val at: Long, val occurrence: Long, val title:String)
    fun wall(value: String): LocalDateTime {
        val plain = value.removeSuffix("Z")
        return if (plain.length == 10) LocalDate.parse(plain).atStartOfDay()
            else if (plain.length == 8) LocalDate.parse(plain, dateCompact).atStartOfDay()
            else if (plain.contains("-")) LocalDateTime.parse(plain)
            else LocalDateTime.parse(plain, compact)
    }
    private fun matchesWeekNumber(parts:Map<String,String>,w:LocalDateTime):Boolean {
        val selection=parts["BYWEEKNO"] ?: return true
        val starts=mapOf("MO" to DayOfWeek.MONDAY,"TU" to DayOfWeek.TUESDAY,"WE" to DayOfWeek.WEDNESDAY,"TH" to DayOfWeek.THURSDAY,"FR" to DayOfWeek.FRIDAY,"SA" to DayOfWeek.SATURDAY,"SU" to DayOfWeek.SUNDAY)
        val fields=WeekFields.of(starts[parts["WKST"] ?: "MO"]!!,4)
        val number=w.get(fields.weekOfWeekBasedYear())
        val year=w.get(fields.weekBasedYear())
        val total=LocalDate.of(year,12,28).get(fields.weekOfWeekBasedYear())
        return selection.split(',').map { it.toInt() }.any { it==number || it==number-total-1 }
    }
    private fun matchesRule(raw:String,start:LocalDateTime,target:LocalDateTime,zone:CalendarNativeZone,allDay:Boolean,floating:Boolean):Boolean {
        val parts=raw.split(';').associate { val p=it.split('=',limit=2);p[0] to p[1] }
        val count=parts["COUNT"]?.toInt()
        val until=parts["UNTIL"]?.let { if(it.endsWith("Z")) wall(it).toInstant(ZoneOffset.UTC) else zone.resolve(wall(it),false) }
        val it=RecurrenceRule(parts.filterKeys { it!="COUNT" && it!="UNTIL" }.entries.joinToString(";") { "${it.key}=${it.value}" })
            .iterator(RfcDate(TimeZone.getTimeZone("UTC"),start.toInstant(ZoneOffset.UTC).toEpochMilli()))
        if(count==null && target>start) it.fastForward(target.toInstant(ZoneOffset.UTC).toEpochMilli())
        var accepted=0
        while(it.hasNext()) {
            val w=LocalDateTime.ofInstant(Instant.ofEpochMilli(it.nextMillis()),ZoneOffset.UTC)
            if(w>target) return false
            val instant=zone.resolve(w,!allDay && !floating) ?: continue
            accepted++
            if(until!=null && instant>until || count!=null && accepted>count) return false
            if(w==target) return true
        }
        return false
    }
    fun next(event: JSONObject, now: Long, deviceZone: ZoneId = ZoneId.systemDefault()): Next? {
        if (event.isNull("reminder_minutes") || event.optBoolean("completed")) return null
        val allDay = event.optBoolean("all_day")
        val floating = event.optString("timezone") == "floating"
        val zone = CalendarNativeZone(event,deviceZone)
        val base = wall(event.optString("start_local").ifEmpty { event.getString("due_local") })
        val due = event.optString("due_local").takeIf { it.isNotEmpty() }?.let { wall(it) }
        val lead = event.getLong("reminder_minutes") * 60000L
        val dueShift = if (due == null) 0L else if (allDay || floating)
            Duration.between(base, due).toMillis() else
            Duration.between(zone.resolve(base, false), zone.resolve(due, false)).toMillis()
        val exceptions = event.optJSONObject("_exceptions") ?: JSONObject()
        val excluded = mutableSetOf<String>()
        fun rid(w: LocalDateTime): String = if (allDay) w.toLocalDate().format(dateCompact)
            else if (floating) w.format(compact)
            else LocalDateTime.ofInstant(zone.resolve(w,false), ZoneOffset.UTC).format(compact)+"Z"
        val exdates = event.optJSONArray("exdates")
        if (exdates != null) for (i in 0 until exdates.length()) {
            val value = exdates.getString(i)
            val w = if(value.endsWith("Z") && !allDay && !floating)
                zone.wall(if(value.contains("-")) Instant.parse(value) else wall(value).toInstant(ZoneOffset.UTC))
                else wall(value)
            excluded.add(rid(w))
        }
        var best: Next? = null
        val detached=event.optJSONObject("_overrides") ?: JSONObject()
        val ranges=event.optJSONArray("_ranges") ?: org.json.JSONArray()
        val maximumShift=(0 until ranges.length()).map { ranges.getJSONObject(it) }.maxOfOrNull {
            kotlin.math.abs(Duration.between(wall(it.getString("wall")),wall(it.getJSONObject("event").getString("start_local"))).toMillis())
        } ?: 0L
        val exrules=event.optJSONArray("_exrules") ?: org.json.JSONArray()
        fun legacyExcluded(w:LocalDateTime):Boolean = (0 until exrules.length()).any { matchesRule(exrules.getString(it),base,w,zone,allDay,floating) }
        for(key in detached.keys()) {
            val e=detached.getJSONObject(key)
            if(excluded.contains(key) || exceptions.optJSONObject(key)?.optString("operation")=="skip" || exceptions.optJSONObject(key)?.optBoolean("completed")==true || e.optBoolean("_cancelled")) continue
            val actual=JSONObject(e.toString()).put("rrule","").put("rdates",org.json.JSONArray()).put("exdates",org.json.JSONArray())
                .put("_overrides",JSONObject()).put("_ranges",org.json.JSONArray()).put("_exceptions",JSONObject()).put("reminder_minutes",event.getInt("reminder_minutes"))
            val n=next(actual,now,deviceZone)
            if(n!=null && (best==null || n.at<best!!.at)) best=n
        }
        fun consider(w: LocalDateTime) {
            val key = rid(w)
            if (excluded.contains(key) || detached.has(key) || legacyExcluded(w)) return
            val exception = exceptions.optJSONObject(key)
            if (exception?.optString("operation") == "skip" || exception?.optBoolean("completed") == true) return
            var template=event
            var target=w
            val matching=(0 until ranges.length()).map { ranges.getJSONObject(it) }.filter { it.getString("rid")<=key }.maxByOrNull { it.getString("rid") }
            if(matching!=null) {
                template=matching.getJSONObject("event")
                if(template.optBoolean("_cancelled")) return
                target=w.plus(Duration.between(wall(matching.getString("wall")),wall(template.getString("start_local"))))
            }
            val templateZone=CalendarNativeZone(template,deviceZone)
            val original=wall(template.optString("start_local").ifEmpty { template.getString("due_local") })
            val targetDue=template.optString("due_local").takeIf { it.isNotEmpty() }?.let { wall(it) }
            val shift=if(targetDue==null) 0L else if(allDay || floating) Duration.between(original,targetDue).toMillis()
                else Duration.between(templateZone.resolve(original,false),templateZone.resolve(targetDue,false)).toMillis()
            val occurrence = if (allDay) templateZone.resolve(target.plusNanos(shift*1000000).toLocalDate().atTime(9,0),false)!!
                else if(floating) templateZone.resolve(target.plusNanos(shift*1000000),false)!!
                else templateZone.resolve(target,false)!!.plusMillis(shift)
            val trigger = occurrence.toEpochMilli()-lead
            if (trigger > now && (best == null || trigger < best!!.at)) best = Next(trigger,occurrence.toEpochMilli(),template.getString("title"))
        }
        val rdates = event.optJSONArray("rdates")
        if(rdates != null) for(i in 0 until rdates.length()) {
            val value = rdates.getString(i).substringBefore('/')
            consider(if(value.endsWith("Z") && !allDay && !floating)
                zone.wall(if(value.contains("-")) Instant.parse(value) else wall(value).toInstant(ZoneOffset.UTC))
                else wall(value))
        }
        val raw = event.optString("rrule").split(';').joinToString(";") { if(it.startsWith("BYSECOND=")) "BYSECOND="+it.substringAfter('=').split(',').map { v -> if(v=="60") "59" else v }.distinct().joinToString(",") else it }
        if(raw.isEmpty()) consider(base) else {
            val parts = raw.split(';').associate { val p=it.split('=',limit=2);p[0] to p[1] }
            val count = parts["COUNT"]?.toInt()
            // BYWEEKNO can select spillover dates from a neighboring week-year.
            // YEARLY INTERVAL still selects calendar years, as CalDAV/dateutil do.
            val yearInterval=if(parts["FREQ"]=="YEARLY" && parts.containsKey("BYWEEKNO")) (parts["INTERVAL"]?.toInt() ?: 1) else 1
            val generatorParts=parts.toMutableMap()
            if(yearInterval>1) generatorParts["INTERVAL"]="1"
            val until = parts["UNTIL"]?.let { if(it.endsWith("Z")) wall(it).toInstant(ZoneOffset.UTC) else zone.resolve(wall(it),false) }
            val stripped = generatorParts.filterKeys { it != "COUNT" && it != "UNTIL" }.entries.joinToString(";") { "${it.key}=${it.value}" }
            // Iterate civil fields in UTC. Resolve gaps before applying COUNT.
            val iterator = RecurrenceRule(stripped, RecurrenceRule.RfcMode.RFC5545_STRICT)
                .iterator(RfcDate(TimeZone.getTimeZone("UTC"),base.toInstant(ZoneOffset.UTC).toEpochMilli()))
            if(count == null) {
                val earliest = zone.wall(Instant.ofEpochMilli(now+lead-dueShift-maximumShift-172800000L))
                if(earliest > base) iterator.fastForward(earliest.toInstant(ZoneOffset.UTC).toEpochMilli())
            }
            var accepted = 0
            while(iterator.hasNext()) {
                val w = LocalDateTime.ofInstant(Instant.ofEpochMilli(iterator.nextMillis()),ZoneOffset.UTC)
                if(yearInterval>1 && (w.year-base.year)%yearInterval!=0 || !matchesWeekNumber(parts,w)) continue
                val instant = zone.resolve(w,!allDay && !floating) ?: continue
                if(until != null && instant > until) break
                accepted++
                if(count != null && accepted > count) break
                consider(w)
                // RDATE already participates in the minimum. Stop after finding
                // a future rule occurrence; no fixed lookahead horizon is needed.
                if(best != null && best!!.at <= instant.toEpochMilli()+dueShift-lead-maximumShift+(if(allDay) 43200000L else 0L) && instant.toEpochMilli()+dueShift-lead > now) break
                if(w.year >= 9999) break
            }
        }
        return best
    }
}
