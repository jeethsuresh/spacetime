package com.jeethsuresh.spacetime

import org.junit.Assert.*
import org.junit.Test
import org.json.JSONObject
import java.time.Instant
import java.time.ZoneId

class ReminderScheduleTest {
    private fun event(start:String, rule:String="", zone:String="UTC", allDay:Boolean=false) = JSONObject()
        .put("id","fixture").put("title","Calendar reminder").put("kind","event")
        .put("timezone",zone).put("all_day",allDay).put("start_local",start)
        .put("rrule",rule).put("reminder_minutes",15)
    private fun at(value:String) = Instant.parse(value).toEpochMilli()
    @Test fun oneOffReminder() {
        val e=event("2026-10-19T09:00:00")
        assertEquals(at("2026-10-19T08:45:00Z"),ReminderSchedule.next(e,at("2026-10-19T08:00:00Z"))!!.at)
        assertNull(ReminderSchedule.next(e,at("2026-10-19T09:01:00Z")))
    }
    @Test fun recurrenceHasNoLookaheadHorizon() {
        val e=event("2026-01-01T09:00:00","FREQ=YEARLY;INTERVAL=50")
        assertEquals(at("2126-01-01T08:45:00Z"),ReminderSchedule.next(e,at("2080-01-01T00:00:00Z"))!!.at)
    }
    @Test fun leapDaysAndMonthly31SkipInvalidDates() {
        val leap=event("2024-02-29T09:00:00","FREQ=YEARLY;COUNT=3")
        assertEquals(at("2028-02-29T08:45:00Z"),ReminderSchedule.next(leap,at("2026-01-01T00:00:00Z"))!!.at)
        val monthly=event("2026-01-31T09:00:00","FREQ=MONTHLY;COUNT=3")
        assertEquals(at("2026-03-31T08:45:00Z"),ReminderSchedule.next(monthly,at("2026-02-01T00:00:00Z"))!!.at)
    }
    @Test fun gapsDoNotConsumeCountAndFoldsChooseFirstInstant() {
        val gap=event("2026-03-07T02:30:00","FREQ=DAILY;COUNT=3","America/New_York")
        assertEquals(at("2026-03-09T06:15:00Z"),ReminderSchedule.next(gap,at("2026-03-08T00:00:00Z"))!!.at)
        assertEquals(at("2026-03-10T06:15:00Z"),ReminderSchedule.next(gap,at("2026-03-10T00:00:00Z"))!!.at)
        assertNull(ReminderSchedule.next(gap,at("2026-03-11T00:00:00Z")))
        val fold=event("2026-10-31T01:30:00","FREQ=DAILY;COUNT=3","America/New_York")
        assertEquals(at("2026-11-01T05:15:00Z"),ReminderSchedule.next(fold,at("2026-11-01T00:00:00Z"))!!.at)
    }
    @Test fun allDayRemindersUseNineAmOnTheDevice() {
        val e=event("2026-10-19","FREQ=YEARLY",allDay=true).put("reminder_minutes",0)
        assertEquals(at("2026-10-19T13:00:00Z"),ReminderSchedule.next(e,at("2026-10-19T00:00:00Z"),ZoneId.of("America/Toronto"))!!.at)
    }
    @Test fun dueDatesAndSkippedCompletedOccurrences() {
        val e=event("2026-01-01T09:00:00","FREQ=DAILY;COUNT=3").put("kind","todo").put("due_local","2026-01-01T17:00:00")
            .put("_exceptions",JSONObject().put("20260101T090000Z",JSONObject().put("completed",true))
                .put("20260102T090000Z",JSONObject().put("operation","skip")))
        assertEquals(at("2026-01-03T16:45:00Z"),ReminderSchedule.next(e,at("2026-01-01T00:00:00Z"))!!.at)
    }
    @Test fun rdateExdateAndUntilUseOriginalRecurrenceIdentity() {
        val e=event("2026-01-01T09:00:00","FREQ=DAILY;UNTIL=20260103T090000Z")
            .put("exdates",org.json.JSONArray().put("2026-01-02T09:00:00"))
            .put("rdates",org.json.JSONArray().put("2026-01-10T09:00:00"))
        assertEquals(at("2026-01-03T08:45:00Z"),ReminderSchedule.next(e,at("2026-01-02T00:00:00Z"))!!.at)
        assertEquals(at("2026-01-10T08:45:00Z"),ReminderSchedule.next(e,at("2026-01-04T00:00:00Z"))!!.at)
    }
    @Test fun embeddedTimeZonesAndMovedExceptionsRemainLocal() {
        val e=event("2026-01-01T09:00:00","FREQ=DAILY;COUNT=2","Custom/Zone")
            .put("_timezones",JSONObject().put("Custom/Zone",org.json.JSONArray().put(JSONObject().put("start","19700101T000000")
                .put("from",19800).put("to",19800).put("rrule","").put("rdates",org.json.JSONArray()))))
        assertEquals(at("2026-01-01T03:15:00Z"),ReminderSchedule.next(e,at("2026-01-01T00:00:00Z"))!!.at)
        val master=event("2026-01-01T09:00:00","FREQ=DAILY;COUNT=2")
        val moved=event("2026-02-01T10:00:00").put("rrule","").put("title","Moved")
        master.put("_overrides",JSONObject().put("20260102T090000Z",moved))
        assertEquals(at("2026-02-01T09:45:00Z"),ReminderSchedule.next(master,at("2026-01-03T00:00:00Z"))!!.at)
    }
    @Test fun legacyExrulesAreAppliedBeforeSelectingTheNextReminder() {
        val e=event("2026-01-01T09:00:00","FREQ=DAILY;COUNT=4").put("_exrules",org.json.JSONArray().put("FREQ=DAILY;INTERVAL=2;COUNT=2"))
        assertEquals(at("2026-01-02T08:45:00Z"),ReminderSchedule.next(e,at("2026-01-01T00:00:00Z"))!!.at)
    }
    @Test fun recurrenceAgreesWithIndependentDateutilFixtures() {
        val raw=javaClass.classLoader!!.getResourceAsStream("recurrence.json")!!.bufferedReader().use { it.readText() }
        val cases=JSONObject(raw).getJSONArray("cases")
        for(i in 0 until cases.length()) {
            val fixture=cases.getJSONObject(i)
            val e=event(fixture.getString("start"),fixture.getString("rule")).put("reminder_minutes",0)
            var after=at(fixture.getString("lower")+"Z")-1
            val expected=fixture.getJSONArray("expected")
            for(n in 0 until expected.length()) {
                val next=ReminderSchedule.next(e,after,ZoneId.of("UTC"))
                assertNotNull(fixture.getString("name"),next)
                assertEquals(fixture.getString("name"),at(expected.getString(n)+"Z"),next!!.occurrence)
                after=next.at
            }
            val next=ReminderSchedule.next(e,after,ZoneId.of("UTC"))
            assertTrue(fixture.getString("name")+" extra="+(next?.occurrence?.let { Instant.ofEpochMilli(it) }),next==null || next.occurrence>=at(fixture.getString("upper")+"Z"))
        }
    }
}
