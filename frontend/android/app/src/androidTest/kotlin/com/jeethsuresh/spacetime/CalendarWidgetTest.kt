package com.jeethsuresh.spacetime

import android.appwidget.AppWidgetManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.os.Build
import android.view.View
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Test
import org.junit.Assert.*
import org.junit.runner.RunWith
import java.io.File
import java.time.*

@RunWith(AndroidJUnit4::class)
class CalendarWidgetTest {
    private val instrumentation get()=InstrumentationRegistry.getInstrumentation()
    private val context get()=instrumentation.targetContext.applicationContext
    @Test fun launcherProvidersExposeTheRequestedSizesWithoutPeriodicWork() {
        val widgets=AppWidgetManager.getInstance(context).installedProviders.filter { it.provider.packageName==context.packageName }
        assertEquals(3,widgets.size)
        for(info in widgets) {
            assertEquals(0,info.updatePeriodMillis)
            if(Build.VERSION.SDK_INT>=31) {
                val shape=when(info.provider.className.substringAfterLast('.')) { "NextAppointmentWidget"->1 to 2;"DayCalendarWidget"->2 to 2;else->4 to 1 }
                assertEquals(shape.first,info.targetCellWidth);assertEquals(shape.second,info.targetCellHeight)
            }
        }
    }
    @Test fun remoteViewsRenderAllThreeWidgetsAndShowCalendarData() {
        val now=System.currentTimeMillis()
        val meeting=ReminderSchedule.Next(now+3600000,now+3600000,"Planning",now+7200000,false,"event","fixture")
        val snapshot=WidgetCalendar.Snapshot(meeting,List(7) { if(it==0 || it==3) listOf(meeting) else emptyList() },now+3600000)
        instrumentation.runOnMainSync {
            for((klass,width,height,name) in listOf(
                Preview(NextAppointmentWidget::class.java,88,174,"next"),
                Preview(DayCalendarWidget::class.java,174,174,"day"),
                Preview(WeekCalendarWidget::class.java,348,88,"week")
            )) {
                val remote=CalendarWidgets.views(context,klass,101,snapshot,true)
                val view=remote.apply(context,FrameLayout(context))
                val density=context.resources.displayMetrics.density
                val w=(width*density).toInt();val h=(height*density).toInt()
                view.measure(View.MeasureSpec.makeMeasureSpec(w,View.MeasureSpec.EXACTLY),View.MeasureSpec.makeMeasureSpec(h,View.MeasureSpec.EXACTLY))
                view.layout(0,0,w,h)
                assertTrue(view.findViewById<View>(R.id.widget_root).hasOnClickListeners())
                if(name=="next") assertEquals("Planning",view.findViewById<TextView>(R.id.widget_title).text.toString())
                if(name=="day") assertEquals("Planning",view.findViewById<TextView>(R.id.widget_row_title).text.toString())
                val bitmap=Bitmap.createBitmap(w,h,Bitmap.Config.ARGB_8888)
                view.draw(Canvas(bitmap))
                File(context.getExternalFilesDir(null),"widget-$name.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG,100,it) }
                bitmap.recycle()
            }
        }
    }
    @Test fun compactDayWidgetKeepsItsRowsInsideTheAvailableHeight() {
        val now=System.currentTimeMillis()
        val events=List(4) { ReminderSchedule.Next(now,now,"Appointment $it",now+3600000) }
        val snapshot=WidgetCalendar.Snapshot(events[0],List(7) { events },now+3600000)
        instrumentation.runOnMainSync {
            val view=CalendarWidgets.views(context,DayCalendarWidget::class.java,102,snapshot,true,130)
                .apply(context,FrameLayout(context))
            val d=context.resources.displayMetrics.density
            val size=(130*d).toInt()
            view.measure(View.MeasureSpec.makeMeasureSpec(size,View.MeasureSpec.EXACTLY),View.MeasureSpec.makeMeasureSpec(size,View.MeasureSpec.EXACTLY))
            view.layout(0,0,size,size)
            val items=view.findViewById<LinearLayout>(R.id.widget_items)
            assertEquals(2,items.childCount)
            assertTrue(items.getChildAt(1).bottom<=items.height)
            assertEquals("Open calendar for more",view.findViewById<TextView>(R.id.widget_empty).text.toString())
        }
    }
    data class Preview(val provider:Class<*>,val width:Int,val height:Int,val name:String)
}
