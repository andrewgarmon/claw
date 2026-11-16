#!/usr/bin/env bash
# shellcheck disable=SC2034  # rc is read inside eval'd check strings
# Tests for infra/brokers/cal.
# 1. The agent-cal wrapper against a fake python and fake id: argument validation, run-as check,
#    secret handling (parsed not sourced; never in argv, the log or stdout). Always runs.
# 2. agent_cal.py end to end against a local Radicale CalDAV server, in a venv built from
#    requirements.txt exactly as on the host (--no-deps, wheels only). Needs network for pip, so
#    it runs in CI (CI=true) or with AGENT_CAL_FULL=1; otherwise it's skipped.
# Touches nothing outside a temp dir. Usage: bash infra/brokers/cal/test.sh
set -uo pipefail
D=$(cd "$(dirname "$0")" && pwd)
LIBSH=$(cd "$D/../../lib" && pwd)/broker.sh
T=$(mktemp -d); trap 'kill "${RAD_PID:-}" 2>/dev/null; rm -rf "$T"' EXIT
H=$T/home BIN=$T/bin AC=$T/agent-cal FAKELIB=$T/lib
mkdir -p "$H/.config" "$BIN" "$FAKELIB/venv/bin"
SECRET=dummy-app-password
printf 'APPLE_ID=owner@example.com\nAPPLE_APP_PASSWORD=%s\n' "$SECRET" > "$H/.config/caldav.env"

sed -e "s|^export PATH=/usr/local/bin:/usr/bin:/bin$|export PATH=$BIN:/usr/bin:/bin|" \
    -e "s|^export HOME=/home/calbot$|export HOME=$H|" \
    -e "s|^\. /usr/local/lib/claw/broker\.sh$|. $LIBSH|" \
    -e "s|^LIB=/usr/local/lib/claw/brokers/cal$|LIB=$FAKELIB|" "$D/agent-cal" > "$AC"
[ "$(grep -c "^export PATH=$BIN:\|^export HOME=$H$\|^\. $LIBSH$\|^LIB=$FAKELIB$" "$AC")" = 4 ] \
  || { echo "FAIL could not point agent-cal at the test dir (did its PATH/HOME/broker.sh/LIB lines change?)"; exit 1; }

cat > "$BIN/id" <<EOF
#!/bin/bash
[ -e "$H/not_calbot" ] && echo openclaw || echo calbot
EOF
# fake venv python: records argv (one per line) and the env it got, prints JSON
cat > "$FAKELIB/venv/bin/python" <<EOF
#!/bin/bash
printf '%s\n' "\$@" > "$T/py.args"
{ echo "id=\${APPLE_ID:-}"; echo "pw=\${APPLE_APP_PASSWORD:-}"; echo "url=\${CALDAV_URL:-}"; echo "state=\${AGENT_CAL_STATE:-}"; } > "$T/py.env"
echo '{"ok": true}'
EOF
chmod +x "$BIN/id" "$FAKELIB/venv/bin/python"

fails=0
run() { rm -f "$T/py.args" "$T/py.env"; : > "$H/agent-cal.log"; bash "$AC" "$@" > "$T/out" 2>&1; rc=$?; }
check() {
  local name=$1; shift
  if "$@"; then echo "ok   $name"; else echo "FAIL $name"; sed 's/^/     out: /' "$T/out"; [ -e "$T/py.args" ] && sed 's/^/     py:  /' "$T/py.args"; fails=$((fails + 1)); fi
}
args_are() { [ -e "$T/py.args" ] && [ "$(cat "$T/py.args")" = "$(printf '%s\n' -I "$FAKELIB/agent_cal.py" "$@")" ]; }
no_py() { [ ! -e "$T/py.args" ]; }
logged() { grep -qE "caller=.* $1" "$H/agent-cal.log"; }
denied() { [ "$rc" = 1 ] && no_py && logged DENY && grep -qF -- "${1:-agent-cal:}" "$T/out"; }
says() { grep -qF -- "$1" "$T/out"; }

# ---------- allowed ----------
run calendars
check "calendars" eval '[ $rc = 0 ] && args_are calendars && logged CALENDARS && says "\"ok\""'
check "credentials reach python through the env" eval 'grep -qx "pw=$SECRET" "$T/py.env" && grep -qx "id=owner@example.com" "$T/py.env" && grep -qx "url=" "$T/py.env"'
check "state dir is calbot's, set by the wrapper" eval 'grep -qx "state=$H/state" "$T/py.env"'
check "secret never in argv, the log or stdout" eval '! grep -q "$SECRET" "$T/py.args" "$H/agent-cal.log" "$T/out"'

run events
check "events: today, all calendars, America/New_York" eval '[ $rc = 0 ] && args_are events America/New_York 1 "" && logged "EVENTS days=1 cal=all"'
run events --days 60 --calendar "Work stuff" --tz Europe/London
check "events: --days 60, --calendar, --tz" eval '[ $rc = 0 ] && args_are events Europe/London 60 "Work stuff"'
run events --tz UTC
check "events: --tz UTC" eval '[ $rc = 0 ] && args_are events UTC 1 ""'

run create --calendar Home --title "Lunch w/ Alex" --start 2026-11-16T12:00 --end 2026-11-16T13:00
check "create: timed" eval '[ $rc = 0 ] && args_are create America/New_York Home "Lunch w/ Alex" 2026-11-16T12:00 2026-11-16T13:00 "" "" && logged "CREATE cal=Home start=2026-11-16T12:00"'
run create --title "Trip" --calendar Home --start 2026-11-20 --end 2026-11-23 --location "Springfield" --notes "$(printf 'pack\nwaders')"
check "create: all-day, any option order, location, multi-line notes" \
  eval '[ $rc = 0 ] && args_are create America/New_York Home Trip 2026-11-20 2026-11-23 "Springfield" "$(printf "pack\nwaders")"'
run create --calendar Home --title "Call" --start 2026-11-16T12:00:00-05:00 --end 2026-11-16T17:30:00Z --tz America/Chicago
check "create: offsets, Z and seconds" eval '[ $rc = 0 ] && args_are create America/Chicago Home Call 2026-11-16T12:00:00-05:00 2026-11-16T17:30:00Z "" ""'
# shellcheck disable=SC2016
run create --calendar Home --title '--title $(id) `x`' --start 2026-11-16T12:00 --end 2026-11-16T13:00
check "create: dash-leading title with \$() and backticks is just a value" \
  eval '[ $rc = 0 ] && grep -qxF -- "--title \$(id) \`x\`" "$T/py.args"'
printf 'APPLE_ID=a\nAPPLE_APP_PASSWORD=b\nCALDAV_URL=http://127.0.0.1:5232/\n' > "$H/.config/caldav.env"
run calendars
check "optional CALDAV_URL passed through" eval '[ $rc = 0 ] && grep -qx "url=http://127.0.0.1:5232/" "$T/py.env"'

ID=0123abcdef
run update --id $ID --title "Lunch moved"
check "update: title only" eval '[ $rc = 0 ] && args_are update America/New_York $ID title "Lunch moved" "" "" "" "" && logged "UPDATE id=$ID fields=title"'
run update --start 2026-11-16T13:00 --id $ID --location ""
check "update: start only (keeps length), empty location clears it" eval '[ $rc = 0 ] && args_are update America/New_York $ID start,location "" 2026-11-16T13:00 "" "" ""'
run update --id $ID --start 2026-11-20 --end 2026-11-21 --notes "$(printf 'a\nb')" --tz UTC
check "update: all-day span and multi-line notes" eval '[ $rc = 0 ] && args_are update UTC $ID start,end,notes "" 2026-11-20 2026-11-21 "" "$(printf "a\nb")"'
run delete --id $ID
check "delete" eval '[ $rc = 0 ] && args_are delete America/New_York $ID && logged "DELETE id=$ID"'
run undo
check "undo: last change" eval '[ $rc = 0 ] && args_are undo America/New_York "" && logged "UNDO change=last"'
run undo --change c12
check "undo: a named change" eval '[ $rc = 0 ] && args_are undo America/New_York c12'
run changes
check "changes" eval '[ $rc = 0 ] && args_are changes America/New_York && logged CHANGES'

# ---------- denied (python never runs) ----------
printf 'APPLE_ID=owner@example.com\nAPPLE_APP_PASSWORD=%s\n' "$SECRET" > "$H/.config/caldav.env"
for d in 0 61 99 abc "1;id" "" -1 " 1"; do
  run events --days "$d"
  check "events: bad --days '$d'" eval 'denied "--days must be"'
done
for tz in "" "../../etc/passwd" "America/New York" "a;b" "/etc/localtime" "$(printf 'a%.0s' {1..41})"; do
  run events --tz "$tz"
  check "bad --tz '${tz:0:20}'" eval 'denied "bad --tz"'
done
run events --calendar "$(printf 'a\nb')"
check "events: newline in --calendar" eval 'denied "bad --calendar"'
run events --days 2 --days 3
check "option given twice" eval 'denied "given twice"'
run events --title x
check "option not allowed for the verb" eval 'denied "unknown option for events"'
run events --days
check "option without a value" eval 'denied "needs a value"'
run events 3
check "bare argument" eval 'denied "unexpected argument"'
run calendars extra
check "calendars takes no arguments" eval 'denied "takes no arguments"'

ok_create=(--calendar Home --title T --start 2026-11-16T12:00 --end 2026-11-16T13:00)
run create --title T --start 2026-11-16T12:00 --end 2026-11-16T13:00
check "create: --calendar required" eval 'denied "--calendar is required"'
run create --calendar Home --start 2026-11-16T12:00 --end 2026-11-16T13:00
check "create: --title required" eval 'denied "--title is required"'
run create --calendar Home --title T --start 2026-11-16T12:00
check "create: --end required" eval 'denied "--start and --end are required"'
for w in "2026-11-16 12:00" "16/11/2026" "2026-11-16T12" "2026-11-16T12:00EST" "tomorrow" "2026-11-16T12:00;id"; do
  run create --calendar Home --title T --start "$w" --end 2026-11-16T13:00
  check "create: bad --start '$w'" eval 'denied "--start and --end are required"'
done
run create --calendar Home --title T --start 2026-11-16 --end 2026-11-16T13:00
check "create: date start with time end" eval 'denied "both be dates"'
run create --calendar Home --title T --start 2026-11-16T12:00 --end 2026-11-17
check "create: time start with date end" eval 'denied "both be dates"'
run create --calendar Home --title "$(printf 'a\nb')" --start 2026-11-16T12:00 --end 2026-11-16T13:00
check "create: newline in title" eval 'denied "--title is required"'
run create --calendar Home --title "$(printf 't%.0s' {1..201})" --start 2026-11-16T12:00 --end 2026-11-16T13:00
check "create: 201-char title" eval 'denied "--title is required"'
run create "${ok_create[@]}" --location "$(printf 'a\tb')"
check "create: control character in location" eval 'denied "bad --location"'
run create "${ok_create[@]}" --notes "$(printf 'a\rb')"
check "create: carriage return in notes" eval 'denied "control characters"'
run create "${ok_create[@]}" --notes "$(printf 'a\033[31mb')"
check "create: escape sequence in notes" eval 'denied "control characters"'
run create "${ok_create[@]}" --notes "$(printf 'n%.0s' {1..2001})"
check "create: notes too long" eval 'denied "--notes too long"'
run create "${ok_create[@]}" --attendee alex@example.com
check "create: no invitations" eval 'denied "unknown option for create"'

for i in "" 0123abcde 0123abcdeff 0123ABCDEF "0123abcde;" "../x" "Dentist"; do
  run delete --id "$i"
  check "delete: bad --id '$i'" eval 'denied "--id is required"'
done
run delete --title Dentist
check "delete by title isn't a thing" eval 'denied "unknown option for delete"'
run update --id $ID
check "update: nothing to change" eval 'denied "nothing to change"'
run update --id $ID --title ""
check "update: empty title" eval 'denied "--title must be"'
run update --id $ID --title "$(printf 'a\nb')"
check "update: newline in title" eval 'denied "--title must be"'
run update --id $ID --start "tomorrow"
check "update: bad --start" eval 'denied "bad --start"'
run update --id $ID --start 2026-11-20 --end 2026-11-20T13:00
check "update: date start with time end" eval 'denied "both be dates"'
run update --id $ID --notes "$(printf 'a\rb')"
check "update: control character in notes" eval 'denied "control characters"'
run update --id $ID --calendar Work
check "update: moving between calendars isn't offered" eval 'denied "unknown option for update"'
run update --id $ID --attendee x@example.com
check "update: no invitations" eval 'denied "unknown option for update"'
for c in "" 12 c0 c "c1;id" C3 c12345678; do
  run undo --change "$c"
  check "undo: bad --change '$c'" eval 'denied "--change must look like"'
done
run changes extra
check "changes takes no bare arguments" eval 'denied "unexpected argument"'

for v in rm edit move invite share ""; do
  run "$v" --calendar Home
  check "no such verb: '${v:-<none>}'" eval '[ $rc = 1 ] && no_py && says "usage:"'
done

# ---------- secrets and run-as ----------
mv "$H/.config/caldav.env" "$H/.config/caldav.env.bak"
run calendars
check "missing secret file: refused" eval 'denied "secret file missing"'
printf 'APPLE_ID=owner@example.com\n' > "$H/.config/caldav.env"
run calendars
check "password missing from caldav.env: refused" eval 'denied "APPLE_APP_PASSWORD missing"'
printf 'APPLE_ID=$(touch %s/pwned)\nAPPLE_APP_PASSWORD=x\n' "$T" > "$H/.config/caldav.env"
run calendars
check "caldav.env is parsed, never sourced" eval '[ $rc = 0 ] && [ ! -e "$T/pwned" ] && grep -qxF "id=\$(touch $T/pwned)" "$T/py.env"'
mv "$H/.config/caldav.env.bak" "$H/.config/caldav.env"

touch "$H/not_calbot"
run calendars
check "not running as calbot: refused before logging or reading the secret" eval '[ $rc = 1 ] && no_py && says "must run as calbot" && [ ! -s "$H/agent-cal.log" ]'
rm "$H/not_calbot"

# ---------- end to end against Radicale ----------
if [ "${CI:-}" = true ] || [ "${AGENT_CAL_FULL:-}" = 1 ]; then
  echo "building venvs (requirements.txt with --no-deps --only-binary=:all: --require-hashes, and radicale)..."
  if python3 -m venv "$T/venv" && "$T/venv/bin/pip" install -q --disable-pip-version-check --require-virtualenv \
       --no-deps --only-binary=:all: --require-hashes -r "$D/requirements.txt" \
     && python3 -m venv "$T/radv" && "$T/radv/bin/pip" install -q --disable-pip-version-check radicale==3.9.1; then
    "$T/venv/bin/python" -I -c 'import caldav, icalendar, recurring_ical_events' \
      && echo "ok   requirements.txt is complete: caldav imports with --no-deps" \
      || { echo "FAIL requirements.txt is missing a dependency"; fails=$((fails + 1)); }
    if AGENT_CAL="$D/lib/agent_cal.py" RADICALE_PY="$T/radv/bin/python" "$T/venv/bin/python" -W ignore "$D/test_agent_cal.py"; then
      echo "ok   agent_cal.py end-to-end tests"
    else
      echo "FAIL agent_cal.py end-to-end tests"; fails=$((fails + 1))
    fi
  else
    echo "FAIL could not build the test venvs"; fails=$((fails + 1))
  fi
else
  echo "skip agent_cal.py end-to-end tests (set AGENT_CAL_FULL=1; CI runs them)"
fi

echo; [ $fails = 0 ] && echo "all agent-cal tests passed" || { echo "$fails failed"; exit 1; }
