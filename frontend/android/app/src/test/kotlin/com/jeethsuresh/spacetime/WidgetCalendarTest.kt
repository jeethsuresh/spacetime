package com.jeethsuresh.spacetime
import org.junit.Test
import org.junit.Assert.*
import org.json.*
import java.time.*

class WidgetCalendarTest {
    @Test fun queuedInvitesFromAnotherAccountStayHidden() {
        val first=JSONObject().put("id","first").put("_account","https://calendar.example#first").put("_response","accepted")
        val second=JSONObject().put("id","second").put("_account","https://calendar.example#second").put("_response","accepted")
        val snapshot=JSONObject().put("server","https://calendar.example")
            .put("user",JSONObject().put("username","second"))
            .put("invitations",JSONArray().put(first).put(second))
        assertEquals(listOf("second"),WidgetCalendar.records(snapshot,true).map { it.getString("id") })
        snapshot.remove("user")
        assertTrue(WidgetCalendar.records(snapshot,true).isEmpty())
    }
    private val utc=ZoneId.of("UTC")
    private fun at(s:String)=Instant.parse(s).toEpochMilli()
    private fun event(id:String,start:String,end:String,kind:String="event",rule:String="")=JSONObject().put("id",id).put("title",id).put("kind",kind).put("all_day",false).put("timezone","UTC").put("start_local",start).put("end_local",end).put("rrule",rule)
    private fun data(vararg e:JSONObject)=JSONObject().put("entries",JSONArray(e.toList()))
    @Test fun appointmentIncludesOngoingAndReplacesItAfterItsEnd() {
        val a=event("Current","2026-10-19T09:00:00","2026-10-19T10:00:00")
        val b=event("Next","2026-10-19T11:00:00","2026-10-19T12:00:00")
        assertEquals("Current",WidgetCalendar.project(data(a,b),true,at("2026-10-19T09:30:00Z"),utc).next!!.title)
        assertEquals("Next",WidgetCalendar.project(data(a,b),true,at("2026-10-19T10:00:00Z"),utc).next!!.title)
    }
    @Test fun multiDayEventsClipIntoDaysAndMidnightIsExclusive() {
        val a=event("Night","2026-10-19T23:00:00","2026-10-20T01:00:00")
        val b=event("Midnight","2026-10-19T22:00:00","2026-10-20T00:00:00")
        val p=WidgetCalendar.project(data(a,b),true,at("2026-10-19T00:00:00Z"),utc)
        assertEquals(2,p.days[0].size);assertEquals(1,p.days[1].size);assertEquals("Night",p.days[1][0].title)
    }
    @Test fun recurrenceRespectsSkipsAndHasNoAppointmentLookaheadCutoff() {
        val e=event("Repeat","2026-10-19T09:00:00","2026-10-19T10:00:00",rule="FREQ=DAILY;COUNT=3")
            .put("_exceptions",JSONObject().put("20261020T090000Z",JSONObject().put("operation","skip")))
        val p=WidgetCalendar.project(data(e),true,at("2026-10-19T00:00:00Z"),utc)
        assertEquals(1,p.days[0].size);assertTrue(p.days[1].isEmpty());assertEquals(1,p.days[2].size)
        val far=event("Far","2026-01-01T09:00:00","2026-01-01T10:00:00",rule="FREQ=YEARLY;INTERVAL=50")
        assertEquals(at("2126-01-01T09:00:00Z"),WidgetCalendar.project(data(far),true,at("2080-01-01T00:00:00Z"),utc).next!!.occurrence)
    }
    @Test fun invitesAreDeduplicatedAndFollowVisibilityWithoutHidingOwnedEntries() {
        val own=event("Owned","2026-10-19T09:00:00","2026-10-19T10:00:00").put("_editable",true)
        val invited=event("Invitation","2026-10-19T11:00:00","2026-10-19T12:00:00").put("_editable",false).put("_remote_id","remote")
        val duplicate=JSONObject(invited.toString()).put("id","remote")
        val snapshot=data(own,invited).put("invitations",JSONArray().put(duplicate))
        assertEquals(2,WidgetCalendar.project(snapshot,true,at("2026-10-19T00:00:00Z"),utc).days[0].size)
        assertEquals(1,WidgetCalendar.project(snapshot,false,at("2026-10-19T00:00:00Z"),utc).days[0].size)
    }
    @Test fun allDayEventsUseDeviceCivilDateAndStayVisibleUntilMidnight() {
        val e=event("All day","2026-10-19","2026-10-20").put("all_day",true)
        val p=WidgetCalendar.project(data(e),true,at("2026-10-19T23:00:00Z"),ZoneId.of("America/Toronto"))
        assertEquals("All day",p.next!!.title);assertEquals(at("2026-10-20T04:00:00Z"),p.next!!.end)
        assertEquals(1,p.days[0].size);assertTrue(p.days[1].isEmpty())
    }
}
