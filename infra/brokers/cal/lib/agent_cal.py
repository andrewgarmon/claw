"""agent-cal's CalDAV client.

Run only by /usr/local/bin/agent-cal (as calbot, with python -I), which has already checked the
arguments' shape and put the credentials and state dir in the environment:
    APPLE_ID, APPLE_APP_PASSWORD, optional CALDAV_URL (default https://caldav.icloud.com/)
    AGENT_CAL_STATE (calbot's private dir: id cache, change history with backups)

    agent_cal.py calendars
    agent_cal.py events  <tz> <days> <calendar or "">
    agent_cal.py create  <tz> <calendar> <title> <start> <end> <location> <notes>
    agent_cal.py update  <tz> <id> <fields> <title> <start> <end> <location> <notes>
                         (fields: comma list of the ones given; an empty location/notes clears it)
    agent_cal.py delete  <tz> <id>
    agent_cal.py undo    <tz> <change or "">
    agent_cal.py changes <tz>

Guardrails, so a wrong or manipulated call stays small and fixable:
- update/delete take an id from a recent `events` listing (7 days), never a title.
- Only single events without attendees can be changed: no recurring series (one call would hit
  every occurrence) and nothing with other people on it (changes can email them).
- Every create/update/delete is recorded with a copy of the event as it was; `undo` puts it back.
  Undo only reverses the newest open change to an event, from the last 7 days, and only if the event
  hasn't been changed since (by the owner or anyone: its ETag must match what we wrote). It re-checks the
  recurring/attendee rule and never re-creates something deleted after our edit.
- Writes use If-Match, so nothing changed between our read and our write is overwritten.
- At most 10 updates+deletes, 20 creates and 20 undos per 24 hours.

Prints JSON on stdout. On failure prints one line on stderr and exits 1. Never prints the
credentials. Event text comes from whoever sent the invite, so callers treat it as data.
"""

import contextlib
import datetime as dt
import fcntl
import hashlib
import json
import os
import re
import sys
import uuid
import zoneinfo

MAX_DAYS = 60          # how far ahead events can look
MAX_EVENT_DAYS = 14    # longest event create/update will make
MAX_EVENTS = 500
MAX_NOTES_OUT = 1000
MAX_TITLE_OUT = 200   # titles come from whoever sent the invite
MAX_CHANGES_PER_DAY = 10   # updates + deletes per rolling 24h (undo doesn't count)
MAX_CREATES_PER_DAY = 20
MAX_UNDOS_PER_DAY = 20
ID_TTL = dt.timedelta(days=7)
HISTORY_KEEP = 200
WHEN_RE = re.compile(r"^\d{4}-\d{2}-\d{2}(T\d{2}:\d{2}(:\d{2})?(Z|[+-]\d{2}:\d{2})?)?$", re.ASCII)
FIELDS = ("title", "start", "end", "location", "notes")


class Fail(Exception):
    """A user-facing error: printed as one line, exit 1."""


def now_utc():
    return dt.datetime.now(dt.timezone.utc)


# ---------- state: id cache and change history, in calbot's private dir ----------

def state_dir():
    d = os.environ.get("AGENT_CAL_STATE")
    if not d:
        raise Fail("AGENT_CAL_STATE not set (run it through agent-cal)")
    os.makedirs(d, mode=0o700, exist_ok=True)
    return d


@contextlib.contextmanager
def locked():
    """One agent-cal at a time touches the state (and the calendar, for changes)."""
    with open(os.path.join(state_dir(), "lock"), "a") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        yield


def load(name, default):
    try:
        with open(os.path.join(state_dir(), name)) as f:
            return json.load(f)
    except FileNotFoundError:
        return default


def save(name, data):
    path = os.path.join(state_dir(), name)
    with open(path + ".tmp", "w") as f:
        json.dump(data, f)
    os.replace(path + ".tmp", path)


def recent(history, actions):
    cutoff = now_utc() - dt.timedelta(days=1)
    return sum(1 for h in history if h["action"] in actions and dt.datetime.fromisoformat(h["at"]) > cutoff)


def check_cap(history, action):
    if action == "undo":
        cutoff = now_utc() - dt.timedelta(days=1)
        if sum(1 for h in history if h.get("undone_at") and dt.datetime.fromisoformat(h["undone_at"]) > cutoff) >= MAX_UNDOS_PER_DAY:
            raise Fail(f"limit reached: {MAX_UNDOS_PER_DAY} undos per 24 hours")
    elif action == "create":
        if recent(history, ("create",)) >= MAX_CREATES_PER_DAY:
            raise Fail(f"limit reached: {MAX_CREATES_PER_DAY} new events per 24 hours")
    elif recent(history, ("update", "delete")) >= MAX_CHANGES_PER_DAY:
        raise Fail(f"limit reached: {MAX_CHANGES_PER_DAY} edits/deletes per 24 hours (undo still works)")


def record(history, entry):
    n = max((h["n"] for h in history), default=0) + 1
    history.append({"n": n, "at": now_utc().isoformat(), "undone": False, **entry})
    save("history.json", history[-HISTORY_KEEP:])
    return f"c{n}"


# ---------- CalDAV ----------

def caldav_url():
    url = os.environ.get("CALDAV_URL") or "https://caldav.icloud.com/"
    # the password goes out with every request: only over TLS (plain http only to this machine, for tests)
    if not re.match(r"^(https://[A-Za-z0-9.-]+(:\d+)?(/.*)?|http://(127\.0\.0\.1|localhost)(:\d+)?(/.*)?)$", url, re.ASCII):
        raise Fail("CALDAV_URL must be https:// (or http:// to localhost)")
    return url


def connect():
    """(client, principal)"""
    import caldav  # imported late so argument errors don't pay for it

    user = os.environ.get("APPLE_ID", "")
    password = os.environ.get("APPLE_APP_PASSWORD", "")
    if not user or not password:
        raise Fail("APPLE_ID or APPLE_APP_PASSWORD missing")
    client = caldav.DAVClient(url=caldav_url(), username=user, password=password, timeout=30)
    return client, client.principal()


def event_calendars(principal):
    """[(name, calendar)] for every collection that holds events (iCloud also lists task lists)."""
    out = []
    for cal in principal.calendars():
        try:
            comps = cal.get_supported_components()
        except Exception:
            comps = None  # server didn't say: assume it holds events
        if comps and "VEVENT" not in comps:
            continue
        name = None
        try:
            name = cal.get_display_name()
        except Exception:
            pass
        out.append((str(name or str(cal.url).rstrip("/").rsplit("/", 1)[-1]), cal))
    return out


def find_calendar(cals, name):
    matches = [c for n, c in cals if n.casefold() == name.casefold()]
    if len(matches) != 1:
        names = ", ".join(sorted(n for n, _ in cals))
        why = "no calendar named" if not matches else "more than one calendar named"
        raise Fail(f"{why} {name!r} (calendars: {names})")
    return matches[0]


def zone(tz):
    try:
        return zoneinfo.ZoneInfo(tz)
    except (zoneinfo.ZoneInfoNotFoundError, ValueError):
        raise Fail(f"unknown time zone: {tz}")


def parse_when(s, tz):
    """'2026-11-16' -> date (all-day); '2026-11-16T12:00[:00][Z|+hh:mm]' -> aware datetime."""
    if not WHEN_RE.match(s):
        raise Fail(f"bad date/time {s!r}: use 2026-11-16T12:00 or 2026-11-16")
    try:
        if "T" not in s:
            return dt.date.fromisoformat(s)
        d = dt.datetime.fromisoformat(s)
    except ValueError as e:
        raise Fail(f"bad date/time {s!r}: {e}")
    return d if d.tzinfo else d.replace(tzinfo=tz)


def check_span(start, end):
    if isinstance(start, dt.datetime) != isinstance(end, dt.datetime):
        raise Fail("start and end must both be dates (all-day) or both be times")
    if end <= start:
        raise Fail("end must be after start (all-day: end is the day after the last day)")
    if end - start > dt.timedelta(days=MAX_EVENT_DAYS):
        raise Fail(f"events longer than {MAX_EVENT_DAYS} days aren't allowed")


def iso(v, tz):
    if isinstance(v, dt.datetime):
        v = v.replace(tzinfo=tz) if v.tzinfo is None else v.astimezone(tz)  # floating times are local
        return v.isoformat(timespec="minutes")
    return v.isoformat()


def text(comp, key, limit=None):
    v = comp.get(key)
    if v is None:
        return ""
    s = str(v).strip()
    return s[:limit] if limit else s


def span(comp):
    start = comp.decoded("dtstart")
    all_day = not isinstance(start, dt.datetime)
    if comp.get("dtend") is not None:
        end = comp.decoded("dtend")
    elif comp.get("duration") is not None:
        end = start + comp.decoded("duration")
    else:
        end = start + dt.timedelta(days=1) if all_day else start
    return start, end, all_day


def normalize(comp, calname, tz):
    """One VEVENT (an expanded occurrence) as a plain dict, times in tz."""
    start, end, all_day = span(comp)
    ev = {"calendar": calname, "title": text(comp, "summary", MAX_TITLE_OUT) or "(no title)",
          "start": iso(start, tz), "end": iso(end, tz), "all_day": all_day}
    if text(comp, "location"):
        ev["location"] = text(comp, "location", 200)
    if text(comp, "description"):
        ev["notes"] = text(comp, "description", MAX_NOTES_OUT)
    return ev


def is_recurring(comp):
    return any(comp.get(k) is not None for k in ("rrule", "rdate", "recurrence-id"))


def sort_key(ev, tz):
    s = ev["start"]
    d = dt.datetime.fromisoformat(s) if "T" in s else dt.datetime.combine(dt.date.fromisoformat(s), dt.time(), tz)
    return (d, not ev["all_day"], ev["title"])


def search(cal, start, end):
    """Expanded occurrences overlapping [start, end) as (VEVENT, resource url)."""
    out = []
    for obj in cal.search(start=start, end=end, event=True, expand=True):
        c = obj.icalendar_component
        if c is not None and str(c.get("status", "")).upper() != "CANCELLED":
            out.append((c, str(obj.url)))
    return out


def event_id(cal_url, uid):
    return hashlib.sha256(f"{cal_url}|{uid}".encode()).hexdigest()[:10]


def editable_resource(event):
    """The single VEVENT of a resource that may be changed, or Fail saying why not."""
    vevents = list(event.icalendar_instance.walk("VEVENT"))
    if len(vevents) != 1 or is_recurring(vevents[0]):
        raise Fail("that's a recurring event; change it in the Calendar app")
    if vevents[0].get("attendee") is not None:
        raise Fail("that event has other people on it; change it in the Calendar app")
    return vevents[0]


def open_event(client, entry):
    """Load the event an id points at; Fail if it's gone or isn't the same event."""
    import caldav

    cal = caldav.Calendar(client=client, url=entry["cal"])
    try:
        ev = cal.event_by_url(entry["href"])
        ev.load()
    except caldav.lib.error.NotFoundError:
        raise Fail("that event no longer exists (deleted or moved); run events again")
    if str(ev.icalendar_component.get("uid")) != entry["uid"]:
        raise Fail("that event changed since the listing; run events again")
    return cal, ev


def etag_of(ev):
    """The resource's current ETag (reloading if the server didn't send one with the last response)."""
    tag = (ev.props or {}).get("{DAV:}getetag")
    if not tag:
        ev.load()
        tag = (ev.props or {}).get("{DAV:}getetag")
    return tag


def remember_id(ident, entry):
    ids = load("ids.json", {})
    ids[ident] = {**entry, "seen": now_utc().isoformat()}
    save("ids.json", ids)


def resolve(ident):
    ids = load("ids.json", {})
    entry = ids.get(ident)
    if not entry or now_utc() - dt.datetime.fromisoformat(entry["seen"]) > ID_TTL:
        raise Fail(f"unknown id {ident}: run events first and use an id from its output")
    return entry


def stamp(ve):
    seq = int(str(ve.get("sequence", 0)) or 0)
    for k in ("sequence", "dtstamp", "last-modified"):
        ve.pop(k, None)
    ve.add("sequence", seq + 1)
    ve.add("dtstamp", now_utc())
    ve.add("last-modified", now_utc())


# ---------- commands ----------

def cmd_calendars():
    _, principal = connect()
    return [{"name": n} for n, _ in sorted(event_calendars(principal), key=lambda x: x[0].casefold())]


def cmd_events(tz_name, days, only):
    tz = zone(tz_name)
    days = int(days)
    if not 1 <= days <= MAX_DAYS:
        raise Fail(f"days must be 1-{MAX_DAYS}")
    start = dt.datetime.combine(dt.datetime.now(tz).date(), dt.time(), tz)
    end = start + dt.timedelta(days=days)
    _, principal = connect()
    cals = event_calendars(principal)
    if only:
        target = find_calendar(cals, only)
        cals = [(n, c) for n, c in cals if c is target]
    events, seen = [], {}
    for name, cal in cals:
        for comp, href in search(cal, start, end):
            ev = normalize(comp, name, tz)
            if is_recurring(comp):
                ev["recurring"] = True
            elif comp.get("attendee") is not None:
                ev["shared"] = True
            else:
                uid = str(comp.get("uid"))
                ev["id"] = event_id(str(cal.url), uid)
                seen[ev["id"]] = {"cal": str(cal.url), "calname": name, "href": href, "uid": uid}
            events.append(ev)
    events.sort(key=lambda e: sort_key(e, tz))
    with locked():
        ids = {k: v for k, v in load("ids.json", {}).items()
               if now_utc() - dt.datetime.fromisoformat(v["seen"]) <= ID_TTL}
        stamp_now = now_utc().isoformat()
        ids.update({k: {**v, "seen": stamp_now} for k, v in seen.items()})
        save("ids.json", ids)
    return events[:MAX_EVENTS]


def cmd_create(tz_name, calname, title, start_s, end_s, location, notes):
    import icalendar

    tz = zone(tz_name)
    start, end = parse_when(start_s, tz), parse_when(end_s, tz)
    check_span(start, end)
    with locked():
        history = load("history.json", [])
        check_cap(history, "create")
        _, principal = connect()
        cals = event_calendars(principal)
        cal = find_calendar(cals, calname)
        calname = next(n for n, c in cals if c is cal)
        all_day = not isinstance(start, dt.datetime)
        result = {"calendar": calname, "title": title, "start": iso(start, tz), "end": iso(end, tz), "all_day": all_day}

        # a retried call (timeout, double message) mustn't make a second copy
        lo = dt.datetime.combine(start, dt.time(), tz) if all_day else start
        hi = dt.datetime.combine(end, dt.time(), tz) if all_day else end
        for c, _ in search(cal, lo, hi):
            if iso(c.decoded("dtstart"), tz) == result["start"] and text(c, "summary").casefold() == title.casefold():
                return {"created": False, "duplicate": True, **result}

        vcal = icalendar.Calendar()
        vcal.add("prodid", "-//claw//agent-cal//EN")
        vcal.add("version", "2.0")
        ev = icalendar.Event()
        uid = f"{uuid.uuid4()}@claw"
        ev.add("uid", uid)
        ev.add("dtstamp", now_utc())
        ev.add("dtstart", start)
        ev.add("dtend", end)
        ev.add("summary", title)
        if location:
            ev.add("location", location)
        if notes:
            ev.add("description", notes)
        vcal.add_component(ev)
        vcal.add_missing_timezones()
        saved = cal.save_event(vcal.to_ical().decode())
        saved.load()
        ref = {"cal": str(cal.url), "calname": calname, "href": str(saved.url), "uid": uid}
        change = record(history, {"action": "create", **ref, "etag": etag_of(saved), "title": title, "start": result["start"]})
        ident = event_id(str(cal.url), uid)
        remember_id(ident, ref)  # usable by update/delete right away
    return {"created": True, **result, "id": ident, "change": change}


def cmd_update(tz_name, ident, fields, title, start_s, end_s, location, notes):
    tz = zone(tz_name)
    given = [f for f in fields.split(",") if f]
    if not given or any(f not in FIELDS for f in given):
        raise Fail("nothing to change: give at least one of --title --start --end --location --notes")
    if "title" in given and not title.strip():
        raise Fail("title can't be empty")
    new_start = parse_when(start_s, tz) if "start" in given else None
    new_end = parse_when(end_s, tz) if "end" in given else None
    with locked():
        entry = resolve(ident)
        history = load("history.json", [])
        check_cap(history, "update")
        client, _ = connect()
        cal, ev = open_event(client, entry)
        before, etag_before = ev.data, etag_of(ev)
        vcal = ev.icalendar_instance
        ve = editable_resource(ev)

        old_start, old_end, old_all_day = span(ve)
        if new_start is not None or new_end is not None:
            if new_start is not None and new_end is None:
                if isinstance(new_start, dt.datetime) == old_all_day:
                    raise Fail("to switch between all-day and timed, give both --start and --end")
                new_end = new_start + (old_end - old_start)  # keep the length
            elif new_end is not None and new_start is None:
                new_start = old_start
                if isinstance(new_end, dt.datetime) == old_all_day:
                    raise Fail("to switch between all-day and timed, give both --start and --end")
            check_span(new_start, new_end)
            for k in ("dtstart", "dtend", "duration"):
                ve.pop(k, None)
            ve.add("dtstart", new_start)
            ve.add("dtend", new_end)
        if "title" in given:
            ve.pop("summary", None)
            ve.add("summary", title)
        for field, prop, value in (("location", "location", location), ("notes", "description", notes)):
            if field in given:
                ve.pop(prop, None)
                if value:
                    ve.add(prop, value)
        stamp(ve)
        vcal.add_missing_timezones()
        ev.data = vcal.to_ical().decode()
        ev.save(precondition="etag", increase_seqno=False)  # If-Match: fails if it changed since we read it
        ev.load()
        after = normalize(ve, entry["calname"], tz)
        change = record(history, {"action": "update", "cal": entry["cal"], "calname": entry["calname"],
                                  "href": entry["href"], "uid": entry["uid"], "etag": etag_of(ev),
                                  "etag_before": etag_before, "title": after["title"], "start": after["start"],
                                  "before": before})
    return {"updated": True, "id": ident, "change": change, **after}


def cmd_delete(tz_name, ident):
    tz = zone(tz_name)
    with locked():
        entry = resolve(ident)
        history = load("history.json", [])
        check_cap(history, "delete")
        client, _ = connect()
        cal, ev = open_event(client, entry)
        before, etag_before = ev.data, etag_of(ev)
        ve = editable_resource(ev)
        gone = normalize(ve, entry["calname"], tz)
        ev.delete(if_match=True)
        change = record(history, {"action": "delete", "cal": entry["cal"], "calname": entry["calname"],
                                  "href": entry["href"], "uid": entry["uid"], "etag_before": etag_before,
                                  "title": gone["title"], "start": gone["start"], "before": before})
    return {"deleted": True, "change": change, **gone}


def cmd_undo(tz_name, change):
    import caldav
    import icalendar

    tz = zone(tz_name)
    with locked():
        history = load("history.json", [])
        if change:
            matches = [h for h in history if f"c{h['n']}" == change]
            if not matches:
                raise Fail(f"no change {change} (see: agent-cal changes)")
            h = matches[0]
        else:
            open_ = [h for h in history if not h["undone"]]
            if not open_:
                raise Fail("nothing to undo")
            h = open_[-1]
        if h["undone"]:
            raise Fail(f"c{h['n']} was already undone")
        if now_utc() - dt.datetime.fromisoformat(h["at"]) > ID_TTL:
            raise Fail(f"c{h['n']} is more than 7 days old; change it in the Calendar app")
        newer = [x for x in history if x["uid"] == h["uid"] and x["n"] > h["n"] and not x["undone"]]
        if newer:
            raise Fail(f"c{newer[-1]['n']} changed that event after c{h['n']}; undo it first")
        check_cap(history, "undo")

        client, _ = connect()
        cal = caldav.Calendar(client=client, url=h["cal"])
        changed_since = (f"that event was changed after c{h['n']} (in the Calendar app or elsewhere), "
                         "so undo won't overwrite it; fix it in the Calendar app")
        if h["action"] in ("create", "update"):
            try:
                ev = cal.event_by_url(h["href"])
                ev.load()
            except caldav.lib.error.NotFoundError:
                raise Fail(f"that event was deleted after c{h['n']}; nothing to undo")
            if str(ev.icalendar_component.get("uid")) != h["uid"] or etag_of(ev) != h.get("etag"):
                raise Fail(changed_since)
            editable_resource(ev)  # it may have become recurring or gained attendees
            if h["action"] == "create":
                h["before"] = ev.data  # kept, so a mistaken undo can still be fixed by hand
                ev.delete(if_match=True)
                new_etag = None
            else:
                was = icalendar.Calendar.from_ical(h["before"])
                ve = next(iter(was.walk("VEVENT")))
                cur_seq = int(str(ev.icalendar_component.get("sequence", 0)) or 0)
                ve.pop("sequence", None)
                ve.add("sequence", cur_seq)
                stamp(ve)  # restored content, newer sequence, so clients take it
                ev.data = was.to_ical().decode()
                ev.save(precondition="etag", increase_seqno=False)
                ev.load()
                new_etag = etag_of(ev)
        else:  # delete: put it back
            try:
                cal.event_by_uid(h["uid"])
                raise Fail("that event is already back on the calendar")
            except caldav.lib.error.NotFoundError:
                pass
            restored = cal.save_event(h["before"])
            restored.load()
            new_etag = etag_of(restored)
            if str(restored.url) != h["href"]:
                h["href"] = str(restored.url)
        h["undone"] = True
        h["undone_at"] = now_utc().isoformat()
        # The event is now as it was just before h. If that's exactly as the previous open change left
        # it (nobody edited it in between), that change can be undone next; otherwise leave its etag
        # alone, so undoing it refuses instead of throwing away the edit made in between.
        prev = [x for x in history if x["uid"] == h["uid"] and x["n"] < h["n"] and not x["undone"]]
        if prev and new_etag and h.get("etag_before") and h.get("etag_before") == prev[-1].get("etag"):
            prev[-1]["etag"] = new_etag
            prev[-1]["href"] = h["href"]
        save("history.json", history)
    out = {"undone": f"c{h['n']}", "action": h["action"], "title": h["title"], "start": h["start"], "calendar": h["calname"]}
    if h["action"] in ("update", "delete"):  # say what's on the calendar now: the event as it was
        was = next(iter(icalendar.Calendar.from_ical(h["before"]).walk("VEVENT")))
        out.update(normalize(was, h["calname"], tz))
    return out


def cmd_changes(tz_name):
    tz = zone(tz_name)
    history = load("history.json", [])
    return [{"change": f"c{h['n']}", "at": iso(dt.datetime.fromisoformat(h["at"]), tz), "action": h["action"],
             "title": h["title"], "start": h["start"], "calendar": h["calname"], "undone": h["undone"]}
            for h in reversed(history[-10:])]


def scrub(msg):
    v = os.environ.get("APPLE_APP_PASSWORD")
    if v:
        msg = msg.replace(v, "***")
    return " ".join(msg.split())[:500]


COMMANDS = {"calendars": (cmd_calendars, 0), "events": (cmd_events, 3), "create": (cmd_create, 7),
            "update": (cmd_update, 8), "delete": (cmd_delete, 2), "undo": (cmd_undo, 2), "changes": (cmd_changes, 1)}


def main(argv):
    os.umask(0o077)
    if not argv or argv[0] not in COMMANDS or len(argv) - 1 != COMMANDS[argv[0]][1]:
        print("agent_cal.py: bad arguments (run it through agent-cal)", file=sys.stderr)
        return 1
    try:
        out = COMMANDS[argv[0]][0](*argv[1:])
    except Fail as e:
        print(f"agent-cal: {scrub(str(e))}", file=sys.stderr)
        return 1
    except Exception as e:  # network, auth, server errors
        name = type(e).__name__
        if name == "AuthorizationError" or "401" in str(e):
            print("agent-cal: iCloud refused the request (401/403): wrong app-specific password, or a read-only calendar.", file=sys.stderr)
        else:
            print(f"agent-cal: {name}: {scrub(str(e))}", file=sys.stderr)
        return 1
    json.dump(out, sys.stdout, ensure_ascii=False, separators=(",", ":"))   # compact: it's read by a model
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
