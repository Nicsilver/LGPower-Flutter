#!/usr/bin/env bash
# Show recent Codemagic (iOS/TestFlight) build statuses for LG Power (Flutter), or how
# much free macOS build time is left this period.
#
# The Android side is checkable with `gh run list`; this is the iOS half of the
# one-tag-both-stores release (see CLAUDE.md "## Releasing"). Codemagic has no
# status CLI, so this hits its REST API.
#
#   bash tools/cm-status.sh            # recent builds
#   bash tools/cm-status.sh 20         # recent builds, more of them
#   bash tools/cm-status.sh minutes    # free macOS minutes left this period
#
# The API token is personal and secret, so it lives OUTSIDE the repo at
# ~/.codemagic-token (Codemagic -> avatar -> User settings -> API token -> Show).
# This script carries no secret and is safe to commit.
set -euo pipefail

TOKEN_FILE="${CODEMAGIC_TOKEN_FILE:-$HOME/.codemagic-token}"
APP_ID="6aa7181b29d4fac9cf2b696b" # LGPower-Flutter
ARG="${1:-6}"

[ -f "$TOKEN_FILE" ] || { echo "missing token file: $TOKEN_FILE" >&2; exit 1; }
# Strip any whitespace/newline so a token restored from the Documents-repo
# backup (which may pick up a trailing newline) can't silently 401.
TOKEN="$(tr -d '[:space:]' < "$TOKEN_FILE")"

case "$ARG" in
  minutes | min | usage)
    # There is no documented usage endpoint. The numbers hang off /user under
    # billing.usage, and they are SECONDS, not minutes - verified by summing the
    # duration of every build in the period and matching the total to within
    # four seconds. freeLimit.buildTime is 30000, i.e. the advertised 500
    # macOS-M2 minutes a month on the free plan.
    curl -s -H "x-auth-token: $TOKEN" "https://api.codemagic.io/user" |
      python -c "
import json, sys
u = json.load(sys.stdin)['user']['billing']['usage']
used = sum(v for k, v in u['currentPeriod']['buildTime'].items() if k.startswith('mac'))
lim = u['freeLimit']['buildTime']
print('macOS build time, current period')
print('  used   %7.1f min  (%d s)' % (used / 60.0, used))
print('  limit  %7.1f min  (%d s)' % (lim / 60.0, lim))
print('  left   %7.1f min' % ((lim - used) / 60.0))
print()
print('  a tagged build runs about 6 min, so roughly %d builds left'
      % ((lim - used) / 360))
"
    ;;
  *)
    curl -s -H "x-auth-token: $TOKEN" \
      "https://api.codemagic.io/builds?appId=$APP_ID&limit=$ARG" |
      python -c "
import json, sys, datetime
for b in json.load(sys.stdin).get('builds', []):
    ref = b.get('tag') or b.get('branch') or '?'
    art = ','.join(a.get('name', '') for a in b.get('artefacts', [])) or '-'
    st, fi = b.get('startedAt'), b.get('finishedAt')
    dur = '-'
    if st and fi:
        d = datetime.datetime.fromisoformat(fi) - datetime.datetime.fromisoformat(st)
        dur = '%.1f min' % (d.total_seconds() / 60.0)
    print(f\"{(st or '?')[:19]}  {b.get('status','?'):9}  {ref:12}  {dur:>8}  {art}\")
"
    ;;
esac
