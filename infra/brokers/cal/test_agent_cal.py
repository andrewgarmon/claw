"""End-to-end tests for agent_cal.py against a local Radicale CalDAV server.

Run by test.sh (CI, or AGENT_CAL_FULL=1) inside a venv built from requirements.txt, with:
  AGENT_CAL    path to lib/agent_cal.py
  RADICALE_PY  a python that has radicale installed
"""

import datetime as dt
import json
import os
import socket
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.request
import zoneinfo

import caldav

os.environ["NO_PROXY"] = os.environ["no_proxy"] = "127.0.0.1,localhost"  # the test server is local
AGENT_CAL = os.environ["AGENT_CAL"]
RADICALE_PY = os.environ["RADICALE_PY"]
NY = zoneinfo.ZoneInfo("America/New_York")
PASSWORD = "dummy-app-password"


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def ics(uid, start, end, summary=None, extra=""):
    def fmt(v):
        if isinstance(v, dt.datetime):
            return f";TZID={v.tzinfo.key}:{v.strftime('%Y%m%dT%H%M%S')}"
        return f";VALUE=DATE:{v.strftime('%Y%m%d')}"
    lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//test//EN", "BEGIN:VEVENT", f"UID:{uid}",
             "DTSTAMP:20260101T000000Z", f"DTSTART{fmt(start)}", f"DTEND{fmt(end)}"]
    if summary is not None:
        lines.append(f"SUMMARY:{summary}")
    lines += [x for x in extra.split("\n") if x] + ["END:VEVENT", "END:VCALENDAR"]
    return "\r\n".join(lines) + "\r\n"


class AgentCal(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        port = free_port()
        cls.url = f"http://127.0.0.1:{port}/"
        cfg = os.path.join(cls.tmp.name, "config")
        with open(cfg, "w") as f:
            # auth delay = 0: Radicale waits ~1 s (by default) before every 401, and the caldav client
            # always sends its first request without credentials, so each agent-cal call paid it once
            f.write(f"[server]\nhosts = 127.0.0.1:{port}\n[auth]\ntype = none\ndelay = 0\n"
                    f"[storage]\nfilesystem_folder = {cls.tmp.name}/collections\n[logging]\nlevel = error\n")
        cls.rad = subprocess.Popen([RADICALE_PY, "-m", "radicale", "--config", cfg],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(100):
            try:
                urllib.request.urlopen(cls.url, timeout=1)
                break
            except urllib.error.HTTPError:
                break
            except Exception:
                time.sleep(0.1)
        cls.env = {"PATH": "/usr/bin:/bin", "APPLE_ID": "owner", "APPLE_APP_PASSWORD": PASSWORD,
                   "CALDAV_URL": cls.url, "NO_PROXY": "*", "no_proxy": "*"}

        p = caldav.DAVClient(url=cls.url, username="owner", password=PASSWORD).principal()
        cls.home = p.make_calendar(name="Home")
        cls.work = p.make_calendar(name="Work")
        cls.tasks = p.make_calendar(name="Reminders", supported_calendar_component_set=["VTODO"])

        cls.today = dt.datetime.now(NY).date()
        t = cls.today
        at = lambda d, h, m=0, tz=NY: dt.datetime.combine(d, dt.time(h, m), tz)
        yesterday, tomorrow = t - dt.timedelta(days=1), t + dt.timedelta(days=1)
        cls.home.save_event(ics("standup", at(yesterday, 9), at(yesterday, 9, 30), "Standup", "RRULE:FREQ=DAILY;COUNT=5"))
        london = zoneinfo.ZoneInfo("Europe/London")
        cls.london_start = at(t, 15, tz=london)
        cls.home.save_event(ics("london", cls.london_start, cls.london_start + dt.timedelta(hours=1), "Call with London"))
        cls.work.save_event(ics("allday", t, tomorrow, "Offsite"))
        cls.work.save_event(ics("cancelled", at(t, 11), at(t, 12), "Cancelled thing", "STATUS:CANCELLED"))
        cls.work.save_event(ics("notitle", at(t, 16), at(t, 17), None, "DESCRIPTION:" + "n" * 1500))
        cls.home.save_event(ics("tomorrow", at(tomorrow, 8), at(tomorrow, 9), "Dentist", "LOCATION:Springfield"))
        cls.work.save_event(ics("shared", at(tomorrow, 14), at(tomorrow, 15), "Team sync",
                                "ORGANIZER:mailto:boss@example.com\nATTENDEE:mailto:owner@example.com"))

    @classmethod
    def tearDownClass(cls):
        cls.rad.terminate()
        cls.rad.wait(10)
        cls.tmp.cleanup()

    def setUp(self):
        # each test gets its own state (id cache, history, daily caps)
        self.state = tempfile.mkdtemp(dir=self.tmp.name)
        self.tenv = {**self.env, "AGENT_CAL_STATE": os.path.join(self.state, "s")}

    def run_cal(self, *args, env=None):
        p = subprocess.run([sys.executable, "-I", AGENT_CAL, *args], env=env or self.tenv,
                           capture_output=True, text=True, timeout=60)
        self.assertNotIn(PASSWORD, p.stdout + p.stderr)
        return p

    def ok(self, *args):
        p = self.run_cal(*args)
        self.assertEqual(p.returncode, 0, p.stderr)
        return json.loads(p.stdout)

    def fails(self, *args, env=None):
        p = self.run_cal(*args, env=env)
        self.assertEqual(p.returncode, 1, p.stdout)
        self.assertEqual(p.stdout, "")
        return p.stderr

    def d(self, days):
        return (self.today + dt.timedelta(days=days)).isoformat()

    def test_long_titles_capped_output_compact(self):
        # far enough ahead that only a 60-day listing sees it
        start = dt.datetime.combine(self.today + dt.timedelta(days=45), dt.time(10), NY)
        self.work.save_event(ics("longtitle", start, start + dt.timedelta(hours=1), "L" * 300))
        p = self.run_cal("events", "America/New_York", "60", "Work")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(p.stdout.count("\n"), 1, "one line of JSON")
        self.assertNotIn('": ', p.stdout)
        [ev] = [e for e in json.loads(p.stdout) if e["title"].startswith("LLL")]
        self.assertEqual(ev["title"], "L" * 200)

    def test_patterns_are_ascii_only(self):
        # Arabic-Indic digits are \d to Python unless re.ASCII
        self.assertIn("use 2026-11-16T12:00", self.fails("create", "America/New_York", "Home", "t",
                                          "\u0662\u0660\u0662\u0666-01-01", "2026-01-02", "", ""))

    def test_calendars_lists_event_calendars_only(self):
        names = [c["name"] for c in self.ok("calendars")]
        self.assertEqual(names, ["Home", "Work"])

    def test_events_today(self):
        evs = self.ok("events", "America/New_York", "1", "")
        titles = [e["title"] for e in evs]
        self.assertEqual(titles, ["Offsite", "Standup", "Call with London", "(no title)"])  # sorted, all-day first
        offsite, standup, london, notitle = evs
        self.assertEqual((offsite["start"], offsite["end"], offsite["all_day"]), (self.d(0), self.d(1), True))
        self.assertEqual(standup["start"], dt.datetime.combine(self.today, dt.time(9), NY).isoformat(timespec="minutes"))
        self.assertFalse(standup["all_day"])
        self.assertEqual(london["start"], self.london_start.astimezone(NY).isoformat(timespec="minutes"))
        self.assertEqual(len(notitle["notes"]), 1000)
        self.assertEqual({e["calendar"] for e in evs}, {"Home", "Work"})
        self.assertNotIn("Cancelled thing", titles)
        self.assertNotIn("Dentist", titles)

    def test_events_days_and_calendar_filter(self):
        evs = self.ok("events", "America/New_York", "2", "home")
        self.assertEqual({e["calendar"] for e in evs}, {"Home"})
        at = lambda h: dt.datetime.combine(self.today + dt.timedelta(days=1), dt.time(h), NY).isoformat(timespec="minutes")
        [dentist] = [e for e in evs if e["title"] == "Dentist"]
        self.assertRegex(dentist.pop("id"), r"^[0-9a-f]{10}$")
        self.assertEqual(dentist, {"calendar": "Home", "title": "Dentist", "start": at(8), "end": at(9),
                                   "all_day": False, "location": "Springfield"})
        self.assertEqual([e["title"] for e in evs].count("Standup"), 2)  # recurring: one per day

    def test_events_other_timezone(self):
        evs = self.ok("events", "Europe/London", "1", "Home")
        london = [e for e in evs if e["title"] == "Call with London"]
        if london:  # unless London's "today" no longer includes it
            self.assertEqual(london[0]["start"], self.london_start.isoformat(timespec="minutes"))

    def test_events_unknown_calendar(self):
        self.assertIn("no calendar named 'Nope' (calendars: Home, Work)", self.fails("events", "America/New_York", "1", "Nope"))

    def test_create_timed_then_duplicate(self):
        start, end = f"{self.d(2)}T12:00", f"{self.d(2)}T13:00"
        out = self.ok("create", "America/New_York", "home", "Lunch w/ Alex", start, end, "Cafe", "line1\nline2")
        self.assertTrue(out["created"])
        self.assertEqual(out["calendar"], "Home")
        self.assertTrue(out["start"].startswith(start))
        again = self.ok("create", "America/New_York", "Home", "lunch w/ alex", start, end, "", "")
        self.assertEqual((again["created"], again.get("duplicate")), (False, True))
        evs = [e for e in self.ok("events", "America/New_York", "3", "Home") if e["title"] == "Lunch w/ Alex"]
        self.assertEqual(len(evs), 1)
        self.assertEqual((evs[0]["location"], evs[0]["notes"]), ("Cafe", "line1\nline2"))

    def test_create_all_day(self):
        out = self.ok("create", "America/New_York", "Work", "Day off", self.d(3), self.d(4), "", "")
        self.assertEqual((out["created"], out["all_day"], out["start"], out["end"]), (True, True, self.d(3), self.d(4)))

    def test_create_with_offset(self):
        out = self.ok("create", "America/New_York", "Work", "Offset call", f"{self.d(5)}T17:00Z", f"{self.d(5)}T18:00Z", "", "")
        self.assertTrue(out["created"])
        self.assertNotIn("Z", out["start"])  # shown in the requested zone

    def test_create_refusals_create_nothing(self):
        before = len(self.home.events())
        self.assertIn("no calendar named", self.fails("create", "America/New_York", "Nope", "x", f"{self.d(2)}T12:00", f"{self.d(2)}T13:00", "", ""))
        self.assertIn("end must be after start", self.fails("create", "America/New_York", "Home", "x", f"{self.d(2)}T13:00", f"{self.d(2)}T12:00", "", ""))
        self.assertIn("end must be after start", self.fails("create", "America/New_York", "Home", "x", self.d(2), self.d(2), "", ""))
        self.assertIn("longer than 14 days", self.fails("create", "America/New_York", "Home", "x", self.d(2), self.d(20), "", ""))
        self.assertIn("both be dates", self.fails("create", "America/New_York", "Home", "x", self.d(2), f"{self.d(2)}T13:00", "", ""))
        self.assertIn("bad date/time", self.fails("create", "America/New_York", "Home", "x", "2026-02-30T12:00", "2026-02-30T13:00", "", ""))
        self.assertIn("bad date/time", self.fails("create", "America/New_York", "Home", "x", "noon", "1pm", "", ""))
        self.assertIn("unknown time zone", self.fails("create", "Mars/Olympus", "Home", "x", f"{self.d(2)}T12:00", f"{self.d(2)}T13:00", "", ""))
        self.assertEqual(len(self.home.events()), before)

    def test_bad_arguments(self):
        self.assertIn("bad arguments", self.fails("events", "America/New_York"))
        self.assertIn("bad arguments", self.fails("delete", "x"))
        self.assertIn("days must be", self.fails("events", "America/New_York", "61", ""))
        self.assertIsInstance(self.ok("events", "America/New_York", "60", ""), list)

    def test_server_errors_never_show_the_password(self):
        err = self.fails("calendars", env={**self.tenv, "CALDAV_URL": "http://127.0.0.1:1/"})
        self.assertIn("ConnectionError", err)

    def test_plain_http_only_to_localhost(self):
        err = self.fails("calendars", env={**self.tenv, "CALDAV_URL": "http://caldav.example.com/"})
        self.assertIn("must be https://", err)

    def test_missing_credentials(self):
        env = {k: v for k, v in self.tenv.items() if k != "APPLE_APP_PASSWORD"}
        self.assertIn("APPLE_APP_PASSWORD missing", self.fails("calendars", env=env))

    # ---------- ids, update, delete, undo, changes ----------

    TZ = "America/New_York"

    def listing(self, title=None, days="30", cal=""):
        evs = self.ok("events", self.TZ, days, cal)
        return [e for e in evs if e["title"] == title] if title else evs

    def make(self, title, day, h=12, cal="Home", minutes=30, location=""):
        start = dt.datetime.combine(self.today + dt.timedelta(days=day), dt.time(h), NY)
        out = self.ok("create", self.TZ, cal, title, start.isoformat(timespec="minutes"),
                      (start + dt.timedelta(minutes=minutes)).isoformat(timespec="minutes"), location, "")
        self.assertTrue(out["created"])
        [ev] = self.listing(title)
        self.assertEqual(ev["id"], out["id"])
        return ev["id"]

    def test_ids_only_for_events_that_can_change(self):
        evs = self.listing(days="2")
        by = {e["title"]: e for e in evs}
        self.assertRegex(by["Dentist"]["id"], r"^[0-9a-f]{10}$")
        standups = [e for e in evs if e["title"] == "Standup"]
        self.assertTrue(standups and all(e.get("recurring") and "id" not in e for e in standups))
        self.assertTrue(by["Team sync"].get("shared") and "id" not in by["Team sync"])

    def test_update_delete_undo_cycle(self):
        i = self.make("Haircut", 8, location="Downtown")
        t = lambda d, h, m=0: dt.datetime.combine(self.today + dt.timedelta(days=d), dt.time(h, m), NY).isoformat(timespec="minutes")

        out = self.ok("update", self.TZ, i, "title,start", "Haircut (moved)", f"{self.d(9)}T15:00", "", "", "")
        self.assertEqual((out["title"], out["start"], out["end"]), ("Haircut (moved)", t(9, 15), t(9, 15, 30)))  # length kept
        self.ok("update", self.TZ, i, "location", "", "", "", "", "")
        [ev] = self.listing("Haircut (moved)")
        self.assertNotIn("location", ev)

        out = self.ok("delete", self.TZ, i)
        self.assertEqual((out["deleted"], out["change"]), (True, "c4"))
        self.assertEqual(self.listing("Haircut (moved)"), [])

        self.assertEqual([(c["change"], c["action"], c["undone"]) for c in self.ok("changes", self.TZ)],
                         [("c4", "delete", False), ("c3", "update", False), ("c2", "update", False), ("c1", "create", False)])

        out = self.ok("undo", self.TZ, "")  # delete -> back, as it was just before
        self.assertEqual((out["undone"], out["title"], out["start"]), ("c4", "Haircut (moved)", t(9, 15)))
        self.assertEqual(len(self.listing("Haircut (moved)")), 1)
        self.ok("undo", self.TZ, "")  # c3: location back
        self.assertEqual(self.listing("Haircut (moved)")[0]["location"], "Downtown")
        out = self.ok("undo", self.TZ, "c2")  # original title and time
        self.assertEqual((out["title"], out["start"]), ("Haircut", t(8, 12)))
        [ev] = self.listing("Haircut")
        self.assertEqual((ev["start"], ev["end"]), (t(8, 12), t(8, 12, 30)))
        self.assertIn("already undone", self.fails("undo", self.TZ, "c2"))
        self.ok("undo", self.TZ, "c1")  # the create
        self.assertEqual(self.listing("Haircut"), [])
        self.assertIn("nothing to undo", self.fails("undo", self.TZ, ""))
        self.assertIn("no change c99", self.fails("undo", self.TZ, "c99"))

    def test_unknown_id(self):
        self.assertIn("unknown id", self.fails("delete", self.TZ, "0123456789"))
        self.assertIn("unknown id", self.fails("update", self.TZ, "0123456789", "title", "x", "", "", "", ""))

    def _server_copy(self, title):
        [obj] = [o for o in self.home.events() if str(o.icalendar_component.get("summary")) == title]
        return obj

    def test_server_side_check_refuses_recurring_and_shared(self):
        # ids are only handed out for single events, but the event is re-checked on the server before
        # any change, in case it became recurring or got attendees since the listing
        i = self.make("Became weekly", 10)
        obj = self._server_copy("Became weekly")
        obj.data = obj.data.replace("END:VEVENT", "RRULE:FREQ=WEEKLY;COUNT=3\r\nEND:VEVENT")
        obj.save()
        self.assertIn("recurring event", self.fails("delete", self.TZ, i))

        j = self.make("Got invitees", 11)
        obj = self._server_copy("Got invitees")
        obj.data = obj.data.replace("END:VEVENT", "ATTENDEE:mailto:alex@example.com\r\nEND:VEVENT")
        obj.save()
        self.assertIn("other people", self.fails("update", self.TZ, j, "title", "x", "", "", "", ""))
        self.assertEqual(self.ok("changes", self.TZ)[0]["action"], "create")  # nothing recorded

    def test_event_gone_elsewhere(self):
        i = self.make("Deleted on phone", 12)
        self._server_copy("Deleted on phone").delete()
        self.assertIn("no longer exists", self.fails("delete", self.TZ, i))

    def test_undo_refuses_after_event_deleted_elsewhere(self):
        i = self.make("Edited then deleted", 13)
        self.ok("update", self.TZ, i, "title", "Edited", "", "", "", "")
        self._server_copy("Edited").delete()
        self.assertIn("deleted after c2", self.fails("undo", self.TZ, ""))
        self.assertEqual(self.listing("Edited then deleted"), [])  # not re-created behind the owner's back

    def test_undo_never_overwrites_later_changes(self):
        # The assistant edits, then the owner edits on their phone: undo must not clobber that edit
        i = self.make("Phone edit", 14)
        self.ok("update", self.TZ, i, "location", "", "", "", "Office", "")
        obj = self._server_copy("Phone edit")
        obj.data = obj.data.replace("LOCATION:Office", "LOCATION:Home office")
        obj.save()
        self.assertIn("changed after c2", self.fails("undo", self.TZ, ""))
        self.assertEqual(self.listing("Phone edit")[0]["location"], "Home office")

        # The assistant creates, then the event gains attendees: undoing the create mustn't delete it
        self.make("Became a meeting", 15)
        obj = self._server_copy("Became a meeting")
        obj.data = obj.data.replace("END:VEVENT", "ATTENDEE:mailto:alex@example.com\r\nEND:VEVENT")
        obj.save()
        self.assertIn("changed after c3", self.fails("undo", self.TZ, "c3"))
        self.assertEqual(len(self.listing("Became a meeting")), 1)

    def test_chained_undo_keeps_an_edit_made_in_between(self):
        # c2 assistant edit -> the owner edits on their phone -> c3 assistant edit -> undo c3 (back to the owner's version)
        # -> undoing c2 must refuse, or the owner's phone edit would be silently lost
        i = self.make("Between edits", 18)
        self.ok("update", self.TZ, i, "location", "", "", "", "Agent 1", "")
        obj = self._server_copy("Between edits")
        obj.data = obj.data.replace("LOCATION:Agent 1", "LOCATION:Owner")
        obj.save()
        self.ok("update", self.TZ, i, "location", "", "", "", "Agent 2", "")
        self.ok("undo", self.TZ, "")  # c3
        self.assertEqual(self.listing("Between edits")[0]["location"], "Owner")
        self.assertIn("changed after c2", self.fails("undo", self.TZ, ""))
        self.assertEqual(self.listing("Between edits")[0]["location"], "Owner")

    def test_undo_newest_change_first(self):
        i = self.make("Two changes", 16)
        self.ok("update", self.TZ, i, "title", "Two changes (edited)", "", "", "", "")
        self.assertIn("c2 changed that event after c1; undo it first", self.fails("undo", self.TZ, "c1"))
        self.ok("undo", self.TZ, "c2")
        self.ok("undo", self.TZ, "c1")
        self.assertEqual(self.listing("Two changes"), [])

    def test_created_id_works_right_away(self):
        start = dt.datetime.combine(self.today + dt.timedelta(days=17), dt.time(10), NY).isoformat(timespec="minutes")
        out = self.ok("create", self.TZ, "Home", "Fresh", start, start[:11] + "11:00" + start[16:], "", "")
        self.assertTrue(self.ok("update", self.TZ, out["id"], "title", "Fresh (renamed)", "", "", "", "")["updated"])

    def test_undo_limits_unit(self):
        # cheap checks of the undo cap and the 7-day window, straight against the module and state
        import importlib.util
        spec = importlib.util.spec_from_file_location("agent_cal", AGENT_CAL)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        recent_ = mod.now_utc().isoformat()
        hist = [{"n": k, "action": "update", "at": recent_, "undone": True, "undone_at": recent_} for k in range(20)]
        with self.assertRaises(mod.Fail):
            mod.check_cap(hist, "undo")
        mod.check_cap(hist[:19], "undo")
        os.makedirs(self.tenv["AGENT_CAL_STATE"], mode=0o700)
        old = (mod.now_utc() - dt.timedelta(days=8)).isoformat()
        with open(os.path.join(self.tenv["AGENT_CAL_STATE"], "history.json"), "w") as f:
            json.dump([{"n": 1, "action": "delete", "at": old, "undone": False, "uid": "u", "cal": self.url,
                        "calname": "Home", "href": "x", "title": "t", "start": "s", "before": ""}], f)
        self.assertIn("more than 7 days old", self.fails("undo", self.TZ, ""))

    def test_switching_all_day_needs_both_ends(self):
        i = self.make("Timed thing", 9, h=9)
        self.assertIn("give both --start and --end", self.fails("update", self.TZ, i, "start", "", self.d(9), "", "", ""))
        out = self.ok("update", self.TZ, i, "start,end", "", self.d(9), self.d(10), "", "")
        self.assertEqual((out["all_day"], out["start"], out["end"]), (True, self.d(9), self.d(10)))
        self.assertIn("end must be after start", self.fails("update", self.TZ, i, "end", "", "", self.d(8), "", ""))

    def test_daily_cap_on_changes(self):
        i = self.make("Busy event", 7, h=7)
        for n in range(10):
            self.ok("update", self.TZ, i, "title", f"Busy {n}", "", "", "", "")
        self.assertIn("limit reached", self.fails("update", self.TZ, i, "title", "one too many", "", "", "", ""))
        self.assertIn("limit reached", self.fails("delete", self.TZ, i))
        self.assertEqual(self.ok("undo", self.TZ, "")["title"], "Busy 8")  # undo still works

    def test_state_is_private(self):
        self.make("Private state", 6, h=6)
        d = self.tenv["AGENT_CAL_STATE"]
        self.assertEqual(os.stat(d).st_mode & 0o777, 0o700)
        for f in ("ids.json", "history.json"):
            self.assertEqual(os.stat(os.path.join(d, f)).st_mode & 0o777, 0o600)


if __name__ == "__main__":
    unittest.main(verbosity=1)
