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
# v0.6.0 with only another asset uploaded, and a release created the same second as v0.6.0.
cur_sums=$(rel v0.6.0 2026-11-22T00:00:00Z false false uploaded 6 |
  jq -c '.assets[0].name = "SHA256SUMS"')
twin=$(rel v0.6.1 2026-11-22T00:00:00Z false false uploaded 61)
other=$(rel vm-kernel 2026-12-02T00:00:00Z false true)
fails=0
# row NAME LIVE WANT RELEASE...: the releases go in as two pages (pagination), in the order given.
# LIVE is "TAG" or "TAG@CREATED" (the created_at the live stamp records).
row() {
  local name=$1 live=${2%@*} created="" want=$3 got
  if [[ "$2" == *@* ]]; then created=${2#*@}; fi
  shift 3
  got=$({ printf '['; printf '%s\n' "$@" | jq -cs '.[:1]'; printf ','
    printf '%s\n' "$@" | jq -cs '.[1:]'; printf ']'; } |
    jq -r --arg asset "$a" --arg live "$live" --arg live_created "$created" -f "$jqf")
  if [ "$got" != "$want" ]; then
    echo "pick-release: $name: got '$got', want '$want'"
    fails=1
  fi
}
t5="take v0.5.0 5 2026-10-01T00:00:00Z sha256:5"
t6="take v0.6.0 6 2026-11-22T00:00:00Z sha256:6"
t7="take v0.7.0 7 2026-12-01T00:00:00Z sha256:7"
c6=2026-11-22T00:00:00Z
row "first deploy, nothing yet" "" none
row "first deploy, only a prerelease" "" none "$other"
row "first deploy, newest in its gap: never the older one" "" "wait v0.6.0" "$cur_gap" "$old"
row "first deploy, no asset anywhere" "" "wait v0.6.0" "$cur_gap" "$other"
row "first deploy" "" "$t6" "$old" "$cur" "$other"
row "first deploy, API order newest first" "" "$t6" "$cur" "$old"
row "first deploy, a newer prerelease does not count" "" "$t6" "$next_pre" "$cur"
row "unchanged" v0.6.0 "$t6" "$next_pre" "$cur" "$old"
row "a newer release" v0.6.0 "$t7" "$cur" "$next" "$old"
row "a newer release, API order newest first" v0.6.0 "$t7" "$next" "$cur" "$old"
row "a newer release while the live one refreshes" v0.6.0 "$t7" "$next" "$cur_gap" "$old"
row "refresh gap: never the older release" v0.6.0 "wait v0.6.0" "$cur_gap" "$old"
row "refresh gap, API order oldest first" v0.6.0 "wait v0.6.0" "$old" "$cur_gap"
row "refresh gap: never none" v0.6.0 "wait v0.6.0" "$cur_gap"
row "another asset does not count" v0.6.0 "wait v0.6.0" "$cur_sums" "$old"
row "upload not finished counts as missing" v0.6.0 "wait v0.6.0" "$cur_new" "$old"
row "a newer draft does not count" v0.6.0 "$t6" "$next_draft" "$cur"
row "a newer draft does not count, live in its gap" v0.6.0 "wait v0.6.0" "$next_draft" "$cur_gap"
row "a newer prerelease does not count" v0.6.0 "wait v0.6.0" "$next_pre" "$cur_gap"
row "a newer release still uploading" v0.6.0 "wait v0.7.0" "$next_gap" "$cur_gap" "$old"
row "a newer release still uploading, the live one served" v0.6.0 "$t6" "$next_gap" "$cur"
row "an older live tag moves forward" v0.5.0 "$t6" "$old_gap" "$cur"
row "live release deleted" "v0.6.0@$c6" "gone v0.6.0" "$old"
row "live release deleted, the stamp records no date" v0.6.0 "gone v0.6.0" "$next" "$old"
row "live release made a prerelease" v0.6.0 "gone v0.6.0" "$cur_pre" "$old"
row "live release made a prerelease, a newer one exists" v0.6.0 "$t7" "$cur_pre" "$next" "$old"
row "live release deleted, a newer one exists" "v0.6.0@$c6" "$t7" "$next" "$old"
row "live release deleted, two newer ones" "v0.5.0@2026-10-01T00:00:00Z" "$t7" "$next" "$cur"
row "live release deleted, a newer one in its gap" "v0.6.0@$c6" "wait v0.7.0" "$next_gap" "$old"
row "live release deleted, a newer prerelease does not count" "v0.6.0@$c6" "gone v0.6.0" \
  "$next_pre" "$old"
row "the live release's own date wins over the stamp's" "v0.5.0@2026-12-31T00:00:00Z" "$t6" \
  "$old_gap" "$cur"
row "live release deleted, one created the same second does not count" "v0.6.0@$c6" \
  "gone v0.6.0" "$twin" "$old"
row "live serves none" none "$t5" "$old"
row "live serves none, the newest with the asset" none "$t5" "$cur_gap" "$old"
row "live serves none, nothing yet" none none "$cur_gap"
if [ "$fails" = 0 ]; then echo "pick-release: all rows pass"; fi
exit "$fails"
