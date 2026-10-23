"""Independent client probe. Starts its own server with a temporary database.
Run: python interop/test_caldav.py --binary /absolute/path/to/spacetime
Requires interop/requirements.txt. No existing calendar data is touched.
"""
import argparse
from datetime import datetime, date, timedelta, timezone
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import tempfile
import time
from urllib.request import Request, urlopen
from zoneinfo import ZoneInfo
import caldav
from icalendar import Calendar, Event, Todo, Timezone

args=argparse.ArgumentParser()
args.add_argument('--binary', required=True)
options=args.parse_args()
with tempfile.TemporaryDirectory(prefix='spacetime-interop-') as folder:
    with socket.socket() as sock:
        sock.bind(('127.0.0.1',0))
        port=sock.getsockname()[1]
    base=f'http://127.0.0.1:{port}'
    invite_key=secrets.token_urlsafe(24)
    env={**os.environ,'ADDR':f'127.0.0.1:{port}','DATA_FILE':str(Path(folder)/'test.db'),'REGISTRATION_INVITE_KEY':invite_key}
    log=open(Path(folder)/'server.log','w+')
    proc=subprocess.Popen([str(Path(options.binary).resolve())],env=env,stdout=log,stderr=log)
    try:
        for _ in range(100):
            try:
                urlopen(base+'/healthz',timeout=.2).close()
                break
            except Exception:
                if proc.poll() is not None:
                    log.seek(0)
                    raise RuntimeError(log.read())
                time.sleep(.05)
        password=secrets.token_urlsafe(24)
        register=Request(base+'/api/register',data=json.dumps({'username':'interop','password':password,'invite_key':invite_key}).encode(),headers={'Content-Type':'application/json'})
        with urlopen(register) as res:
            token=json.load(res)['token']
        client=caldav.DAVClient(url=base+'/dav/',username='interop',password=password)
        principal=client.principal()
        calendars=principal.calendars()
        assert len(calendars)==1, 'Principal discovery must expose one calendar'
        calendar=calendars[0]
        zone=ZoneInfo('America/Toronto')
        cal=Calendar()
        cal.add('prodid','-//Spacetime independent interop test//EN')
        cal.add('version','2.0')
        cal.add_component(Timezone.from_tzinfo(zone,first_date=date(2020,1,1),last_date=date(2035,12,31)))
        event=Event()
        event.add('uid','independent-recurring-test@spacetime')
        event.add('dtstamp',datetime.now(timezone.utc))
        event.add('dtstart',datetime(2026,10,30,9,tzinfo=zone))
        event.add('dtend',datetime(2026,10,30,10,tzinfo=zone))
        event.add('summary','Independent recurring probe')
        event.add('rrule',{'freq':['DAILY'],'count':[4]})
        event.add('exdate',datetime(2026,10,31,9,tzinfo=zone))
        event.add('rdate',datetime(2026,11,4,9,tzinfo=zone))
        event.add('x-independent-property','must survive')
        cal.add_component(event)
        saved=calendar.save_event(cal.to_ical().decode())
        saved.load()
        work=principal.make_calendar(name='Work',cal_id='independent-work',method='mkcalendar')
        assert len(principal.calendars())==2, 'Second collection must be discoverable'
        workcal=Calendar.from_ical(cal.to_ical())
        workcal.walk('VEVENT')[0]['SUMMARY']='Same UID in Work'
        work_saved=work.save_event(workcal.to_ical().decode())
        work_saved.load()
        assert 'Same UID in Work' in work_saved.data
        saved.load()
        assert 'Independent recurring probe' in saved.data and 'Same UID in Work' not in saved.data
        work_saved.delete()
        assert not work.events()
        assert b'X-INDEPENDENT-PROPERTY:must survive' in saved.data.encode()
        results=calendar.search(start=datetime(2026,10,29,tzinfo=timezone.utc),end=datetime(2026,11,6,tzinfo=timezone.utc),event=True,expand=True,server_expand=True,post_filter=False,compatibility_workarounds=False)
        actual=[]
        for result in results:
            parsed=Calendar.from_ical(result.data)
            for component in parsed.walk('VEVENT'):
                actual.append(component.decoded('dtstart').astimezone(timezone.utc).isoformat())
                assert component.get('rrule') is None
                assert component.get('recurrence-id') is not None
        expected=['2026-10-30T13:00:00+00:00','2026-11-01T14:00:00+00:00','2026-11-02T14:00:00+00:00','2026-11-04T14:00:00+00:00']
        assert sorted(actual)==expected, (actual,expected)
        taskcal=Calendar()
        taskcal.add('prodid','-//Independent test//EN')
        taskcal.add('version','2.0')
        task=Todo()
        task.add('uid','independent-todo@spacetime')
        task.add('dtstamp',datetime.now(timezone.utc))
        task.add('due',datetime(2026,11,1,17,tzinfo=timezone.utc))
        task.add('summary','Independent task')
        task.add('status','NEEDS-ACTION')
        taskcal.add_component(task)
        saved_task=calendar.save_todo(taskcal.to_ical().decode())
        tasks=calendar.search(todo=True,include_completed=True,post_filter=False,compatibility_workarounds=False)
        assert len(tasks)==1
        saved_task.load()
        loaded=Calendar.from_ical(saved_task.data)
        loaded.walk('VTODO')[0]['SUMMARY']='Independent task updated'
        saved_task.data=loaded.to_ical().decode()
        saved_task.save()
        saved_task.load()
        assert 'Independent task updated' in saved_task.data
        saved_task.delete()
        saved.delete()
        assert not calendar.events()
        print(json.dumps({'result':'PASS','client':f'python-caldav {caldav.__version__}','checks':['principal and collection discovery','MKCALENDAR and collection-scoped same UID','VEVENT/VTODO writes and reads','server-side expansion with client workarounds disabled','DST wall-clock preservation','RDATE/EXDATE','recurrence identifiers and UTC expansion','unknown-property preservation','update and delete']},indent=2))
    finally:
        proc.terminate()
        proc.wait(timeout=5)
        log.close()
