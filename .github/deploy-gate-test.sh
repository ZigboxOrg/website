#!/usr/bin/env bash
# Tests `deploy.sh gate` end to end: a local HTTP server stands in for zigbox.org, and the
# GATE_* hooks for the GitHub API. Each scenario checks the `deploy` output, a line of the log
# and, when it deploys, the stamp's packages line.
# Usage: deploy-gate-test.sh (from anywhere; needs jq, curl, python3). Exit 1 on any failure.
set -euo pipefail
gate=$(cd "$(dirname "$0")" && pwd)/deploy.sh
work=$(mktemp -d)
server=""
# shellcheck disable=SC2329 # run by the trap
cleanup() {
  if [ -n "$server" ]; then kill "$server" 2> /dev/null || true; fi
  rm -rf "$work"
}
trap cleanup EXIT
signed=(apt/dists/stable/Release apt/dists/stable/Release.gpg apt/dists/stable/InRelease
  rpm/x86_64/repodata/repomd.xml rpm/x86_64/repodata/repomd.xml.asc
  rpm/aarch64/repodata/repomd.xml rpm/aarch64/repodata/repomd.xml.asc
  zigbox-archive-keyring.gpg zigbox-archive-keyring.asc)

# The fake zigbox.org: serves $work/www (no logging).
mkdir -p "$work/www"
python3 -I -c '
import functools, http.server, sys
class H(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a): pass
s = http.server.ThreadingHTTPServer(("127.0.0.1", 0),
    functools.partial(H, directory=sys.argv[1]))
print(s.server_address[1], flush=True)
s.serve_forever()
' "$work/www" > "$work/port" &
server=$!
for _ in $(seq 50); do [ -s "$work/port" ] && break; sleep 0.1; done
site=http://127.0.0.1:$(cat "$work/port")
# A port nothing listens on: the stamp answers 000.
down=http://127.0.0.1:$(python3 -I -c '
import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')

ago() { date -u -d "$1 ago" +%Y-%m-%dT%H:%M:%SZ; }
# rel TAG CREATED UPDATED [ID]: a published release, with an uploaded asset when ID is given.
rel() {
  jq -cn --arg t "$1" --arg c "$2" --arg u "$3" --arg i "${4:-}" '{tag_name: $t, created_at: $c,
    updated_at: $u, draft: false, prerelease: false, assets: (if $i == "" then [] else
    [{name: "zigbox-repos.tar.gz", state: "uploaded", id: ($i | tonumber),
      digest: "sha256:\($i)"}] end)}'
}
c5=2026-10-01T00:00:00Z
c6=2026-11-22T15:35:25Z
c7=2026-12-01T00:00:00Z
old=$(rel v0.5.0 $c5 $c5 5)
cur=$(rel v0.6.0 $c6 $c6 6)
cur_gap=$(rel v0.6.0 $c6 "$(ago '10 minutes')")
cur_lost=$(rel v0.6.0 $c6 "$(ago '3 hours')")
next=$(rel v0.7.0 $c7 $c7 7)
releases() { printf '%s\n' "$@" | jq -s '[.]' > "$work/releases.json"; }

# The live site: the nine signed files, and a stamp for packages $1 ("" for no stamp, "none",
# or "TAG [CREATED] sha256:HEX"); more lines may follow in $2.
serve() {
  local f
  rm -rf "$work/www"/*
  for f in "${signed[@]}"; do mkdir -p "$work/www/$(dirname "$f")"; echo "$f" > "$work/www/$f"; done
  [ -n "$1" ] || return 0
  {
    printf 'site s\nzigbox b\nzigcube c\npackages %s\n' "$1"
    if [ "$1" != none ]; then
      for f in "${signed[@]}"; do echo "file $(sha256sum < "$work/www/$f" | cut -d' ' -f1) $f"; done
    fi
    printf '%s' "${2:-}"
  } > "$work/www/deploy-stamp.txt"
}

fails=0
# scenario NAME EVENT DEPLOY LOG [PACKAGES]: runs the gate (environment from HAVE_CF, ALLOW_OLDER
# and SITE as set); checks deploy=DEPLOY, a log line matching LOG (grep -E) and, when given, the
# stamp's packages line.
scenario() {
  local name=$1 event=$2 want=$3 log=$4 pkgs=${5:-} dir got rc=0
  dir=$(mktemp -d "$work/run.XXXX")
  (cd "$dir" && EVENT=$event SELF_SHA=s HAVE_CF=${HAVE_CF:-true} ALLOW_OLDER=${ALLOW_OLDER:-false} \
    SITE=${SITE:-$site} GITHUB_OUTPUT=$dir/out GATE_BOX=b GATE_CUBE=c \
    GATE_RELEASES=$work/releases.json "$gate" gate > "$dir/log" 2>&1) || rc=$?
  got=$(sed -n 's/^deploy=//p' "$dir/out" 2> /dev/null | tail -n 1)
  if [ "$rc" != 0 ] || [ "$got" != "$want" ]; then
    echo "deploy-gate: $name: exit $rc, deploy='$got', want '$want'"; sed 's/^/  | /' "$dir/log"
    fails=1; return
  fi
  if ! grep -qE -- "$log" "$dir/log"; then
    echo "deploy-gate: $name: no log line matches '$log'"; sed 's/^/  | /' "$dir/log"
    fails=1; return
  fi
  if [ -n "$pkgs" ] && ! grep -qx -- "packages $pkgs" "$dir/stamp-core.txt"; then
    echo "deploy-gate: $name: stamp says '$(grep '^packages' "$dir/stamp-core.txt")'," \
      "want 'packages $pkgs'"
    fails=1
  fi
}
nowarn='^(not deployed|unchanged)'
p6="v0.6.0 $c6 sha256:6"

# No stamp yet (a first deploy).
releases "$old" "$cur"
serve ""
scenario "no stamp: the newest release" schedule true '^changed' "$p6"
releases "$old" "$cur_gap"
scenario "no stamp, the newest in its gap: wait, never the older one" schedule false \
  '^not deployed: zigbox-repos.tar.gz of v0.6.0 is not uploaded'
scenario "no stamp, in a gap, on a push: warns" push false '^::warning::not deployed: .* v0.6.0'
releases
scenario "no stamp, no release: none" push true '^deploy: a push run' "none"

# A matching stamp, and the files it names.
releases "$old" "$cur"
serve "$p6"
scenario "unchanged" schedule false '^unchanged'
scenario "unchanged, on a push: deploys" push true '^deploy: a push run' "$p6"
echo changed > "$work/www/apt/dists/stable/Release.gpg"
scenario "a changed signed file" schedule true \
  '^changed: /apt/dists/stable/Release.gpg answered 200'
serve "$p6"
rm "$work/www/rpm/aarch64/repodata/repomd.xml.asc"
scenario "a missing signed file" schedule true \
  '^changed: /rpm/aarch64/repodata/repomd.xml.asc answered 404'
# A redirect with an empty body, where the stamp names an empty file: the status counts too.
serve "$p6"
empty=$(sha256sum < /dev/null | cut -d' ' -f1)
sed -i "s|^file [0-9a-f]* zigbox-archive-keyring.asc\$|file $empty zigbox-archive-keyring.asc|" \
  "$work/www/deploy-stamp.txt"
rm "$work/www/zigbox-archive-keyring.asc"
mkdir "$work/www/zigbox-archive-keyring.asc"
scenario "a redirect with the stamped bytes" schedule true \
  '^changed: /zigbox-archive-keyring.asc answered 301'
serve "v0.6.0 sha256:6"
scenario "a stamp of the older format" schedule true '^changed: zigbox.org.s stamp differs' "$p6"
serve "$p6" "zigbox other
"
scenario "another zigbox commit" schedule true '^changed: zigbox.org.s stamp differs'

# The refresh's gap.
serve "$p6"
releases "$old" "$cur_gap"
scenario "refresh gap: wait, no warning" schedule false \
  '^not deployed: zigbox-repos.tar.gz of v0.6.0 is not uploaded'
scenario "refresh gap on a push: warns" push false \
  '^::warning::not deployed: .* v0.6.0 is not uploaded'
scenario "refresh gap on a dispatch: warns" workflow_dispatch false '^::warning::not deployed'
releases "$old" "$cur_lost"
scenario "an asset missing for 3 hours: warns" schedule false '^::warning::not deployed: .* v0.6.0'
releases "$old" "$cur_gap" "$next"
scenario "refresh gap, a newer release: takes it" schedule true '^changed' "v0.7.0 $c7 sha256:7"

# The Cloudflare secrets.
releases "$old" "$cur"
HAVE_CF=false scenario "secrets unset on a schedule: warns" schedule false \
  '^::warning::not deployed: the CLOUDFLARE_API_TOKEN'
HAVE_CF=false scenario "secrets unset on a push: goes on" push true '^deploy: a push run' "$p6"

# The live release deleted.
releases "$old"
scenario "live release gone: warns" schedule false \
  '^::warning::not deployed: zigbox.org serves v0.6.0, which is no longer'
scenario "live release gone, on a push: warns" push false \
  '^::warning::not deployed: zigbox.org serves v0.6.0'
ALLOW_OLDER=true scenario "live release gone, allow_older_packages" workflow_dispatch true \
  '^packages: v0.6.0 is no longer a published release' "v0.5.0 $c5 sha256:5"
releases "$old" "$next"
scenario "live release gone, a newer one: takes it" schedule true '^changed' "v0.7.0 $c7 sha256:7"
serve "v0.6.0 sha256:6"
scenario "live release gone, a stamp with no date: warns" schedule false \
  '^::warning::not deployed: zigbox.org serves v0.6.0, which is no longer'
serve "$p6"
releases "$old" "$cur" "$(rel v0.7.0 $c7 "$(ago '10 minutes')")"
ALLOW_OLDER=true scenario "allow_older_packages, the live release still published" \
  workflow_dispatch true '^deploy: a workflow_dispatch run' "$p6"
releases
ALLOW_OLDER=true scenario "allow_older_packages with no release: never none" \
  workflow_dispatch false \
  '^::warning::not deployed: no published release exists'

# A stamp that cannot be read.
releases "$old" "$cur"
serve "" ; printf 'site s\nzigbox b\n' > "$work/www/deploy-stamp.txt"
scenario "a stamp with no packages line, on a schedule: warns" schedule false \
  '^::warning::not deployed: .*names no packages tag'
scenario "a stamp with no packages line, on a push: deploys the newest" push true \
  '^::warning::.*names no packages tag; a push run deploys' "$p6"
releases "$old" "$cur_gap"
scenario "an unreadable stamp in a gap, on a push: never the older one" push false \
  '^::warning::not deployed: .* v0.6.0 is not uploaded'
releases "$old" "$cur"
SITE=$down scenario "zigbox.org down, on a schedule: warns" schedule false \
  '^::warning::not deployed: .*answered 000'
SITE=$down scenario "zigbox.org down, on a dispatch: deploys" workflow_dispatch true \
  '^::warning::.*answered 000; a workflow_dispatch run deploys' "$p6"

# A scenario that skips without a warning must not print one.
releases "$old" "$cur_gap"
serve "$p6"
dir=$(mktemp -d "$work/run.XXXX")
(cd "$dir" && EVENT=schedule SELF_SHA=s HAVE_CF=true SITE=$site GITHUB_OUTPUT=$dir/out GATE_BOX=b \
  GATE_CUBE=c GATE_RELEASES=$work/releases.json "$gate" gate > "$dir/log" 2>&1)
if grep -q '::warning::' "$dir/log" || ! grep -qE "$nowarn" "$dir/log"; then
  echo "deploy-gate: a short refresh gap on a schedule warns"; fails=1
fi

if [ "$fails" = 0 ]; then echo "deploy-gate: all scenarios pass"; fi
exit "$fails"
