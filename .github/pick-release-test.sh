#!/usr/bin/env bash
# Table test of pick-release.jq: deploy, skip, never backwards, and the refresh's gap.
# Usage: pick-release-test.sh (from anywhere; needs jq). Exit 1 with one line per failed row.
set -euo pipefail
jqf=$(dirname "$0")/pick-release.jq
a=zigbox-repos.tar.gz
# rel TAG CREATED DRAFT PRERELEASE [STATE ID]: one release, with the asset when STATE is given.
rel() {
  jq -cn --arg t "$1" --arg c "$2" --argjson d "$3" --argjson p "$4" --arg s "${5:-}" \
    --arg i "${6:-0}" --arg a "$a" '{tag_name: $t, created_at: $c, draft: $d, prerelease: $p,
      assets: (if $s == "" then [] else [{name: $a, state: $s, id: ($i | tonumber),
        digest: "sha256:\($i)"}] end)}'
}
old=$(rel v0.5.0 2026-10-01T00:00:00Z false false uploaded 5)
old_gap=$(rel v0.5.0 2026-10-01T00:00:00Z false false)
cur=$(rel v0.6.0 2026-11-22T00:00:00Z false false uploaded 6)
cur_gap=$(rel v0.6.0 2026-11-22T00:00:00Z false false)
cur_new=$(rel v0.6.0 2026-11-22T00:00:00Z false false starter 6)
cur_pre=$(rel v0.6.0 2026-11-22T00:00:00Z false true uploaded 6)
next=$(rel v0.7.0 2026-12-01T00:00:00Z false false uploaded 7)
next_gap=$(rel v0.7.0 2026-12-01T00:00:00Z false false)
next_draft=$(rel v0.7.0 2026-12-01T00:00:00Z true false uploaded 7)
next_pre=$(rel v0.7.0 2026-12-01T00:00:00Z false true uploaded 7)
other=$(rel vm-kernel 2026-12-02T00:00:00Z false true)
fails=0
# row NAME LIVE WANT RELEASE...: the releases go in as two pages (pagination), in the order given.
row() {
  local name=$1 live=$2 want=$3 got
  shift 3
  got=$({ printf '['; printf '%s\n' "$@" | jq -cs '.[:1]'; printf ','
    printf '%s\n' "$@" | jq -cs '.[1:]'; printf ']'; } |
    jq -r --arg asset "$a" --arg live "$live" -f "$jqf")
  if [ "$got" != "$want" ]; then
    echo "pick-release: $name: got '$got', want '$want'"
    fails=1
  fi
}
row "first deploy, nothing yet" "" none
row "first deploy, no asset anywhere" "" none "$cur_gap" "$other"
row "first deploy" "" "take v0.6.0 6 sha256:6" "$old" "$cur" "$other"
row "first deploy, API order newest last" "" "take v0.6.0 6 sha256:6" "$cur" "$old"
row "unchanged" v0.6.0 "take v0.6.0 6 sha256:6" "$next_pre" "$cur" "$old"
row "a newer release" v0.6.0 "take v0.7.0 7 sha256:7" "$cur" "$next" "$old"
row "a newer release while the live one refreshes" v0.6.0 "take v0.7.0 7 sha256:7" \
  "$cur_gap" "$next" "$old"
row "refresh gap: never the older release" v0.6.0 "wait v0.6.0" "$cur_gap" "$old"
row "refresh gap: never none" v0.6.0 "wait v0.6.0" "$cur_gap"
row "upload not finished counts as missing" v0.6.0 "wait v0.6.0" "$cur_new" "$old"
row "a newer draft does not count" v0.6.0 "take v0.6.0 6 sha256:6" "$next_draft" "$cur"
row "a newer prerelease does not count" v0.6.0 "wait v0.6.0" "$next_pre" "$cur_gap"
row "a newer release still uploading" v0.6.0 "wait v0.6.0" "$next_gap" "$cur_gap" "$old"
row "an older live tag moves forward" v0.5.0 "take v0.6.0 6 sha256:6" "$old_gap" "$cur"
row "live release deleted" v0.6.0 "gone v0.6.0" "$old"
row "live release made a prerelease" v0.6.0 "gone v0.6.0" "$cur_pre" "$old"
row "live release deleted, a newer one exists" v0.6.0 "gone v0.6.0" "$next" "$old"
row "live serves none" none "take v0.5.0 5 sha256:5" "$old"
row "live serves none, nothing yet" none none "$cur_gap"
if [ "$fails" = 0 ]; then echo "pick-release: all rows pass"; fi
exit "$fails"
