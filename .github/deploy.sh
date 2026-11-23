#!/usr/bin/env bash
# The deploy workflow's logic (.github/workflows/deploy.yml), in one place so it can be run and
# tested outside Actions. Run from the workspace root (the directory above the checkout `self`).
#
#   deploy.sh gate      decides whether this run deploys; writes stamp-core.txt and the step's
#                       outputs (deploy, box, cube, tag, asset_id, sum)
#   deploy.sh packages  fetches, checks and unpacks the packages asset into pkg/tree, writes
#                       pkg/manifest and stamp.txt; output go=true when the run goes on
#   deploy.sh check     after the deploy: zigbox.org serves every package file and the stamp
#   deploy.sh verify T  checks the signatures of an unpacked asset T against the owner's key
#
# Environment: SITE (default https://zigbox.org), GITHUB_OUTPUT (default /dev/null), GH_TOKEN;
# gate: EVENT, SELF_SHA, HAVE_CF (true when the Cloudflare secrets are set), ALLOW_OLDER (true
# only from a workflow_dispatch input); packages: TAG, ASSET_ID, SUM.
# GATE_BOX, GATE_CUBE and GATE_RELEASES (a file) replace the API reads, for tests only.
set -euo pipefail

site=${SITE:-https://zigbox.org}
out=${GITHUB_OUTPUT:-/dev/null}
here=$(cd "$(dirname "$0")" && pwd)
asset=zigbox-repos.tar.gz
# The owner's release key (Zigbox's docs/releases/packaging.md, "The release key"): RSA 4096,
# certify-only primary. Never the fixed Ed25519 test key of `zig build packages -Dtest-key`.
# A new primary is a reviewed change here, made with the one in Zigbox's release.yml.
owner_key=1207CB8600CE25FFDD3CC87ECCBEC141C3348787
# What apt and dnf fetch whose bytes change with every signing (the same nine as Zigbox's
# .github/actions/site-serves/wait.sh). Their sha256 are in the stamp as `file <sha256> <path>`.
signed=(
  apt/dists/stable/Release
  apt/dists/stable/Release.gpg
  apt/dists/stable/InRelease
  rpm/x86_64/repodata/repomd.xml
  rpm/x86_64/repodata/repomd.xml.asc
  rpm/aarch64/repodata/repomd.xml
  rpm/aarch64/repodata/repomd.xml.asc
  zigbox-archive-keyring.gpg
  zigbox-archive-keyring.asc
)
retry=(--retry 3 --retry-all-errors --max-time 60)

# GET $site/$1 into $2 (no redirect followed, nothing decoded); prints the status, 000 on failure.
get() {
  local code
  code=$(curl -sS "${retry[@]}" -o "$2" -w '%{http_code}' "$site/$1" 2> /dev/null) || code=000
  echo "$code"
}

# Ends the run without deploying, successfully: prints why (with ::warning:: when $2 is warn).
skip() {
  if [ "${2:-}" = warn ]; then echo "::warning::$1"; else echo "$1"; fi
  echo "deploy=false" >> "$out"
  exit 0
}

# Sets `live` to the tag the live stamp names: a tag, "none", or "" when zigbox.org has no stamp
# (404). Skips the run when the stamp cannot be read, as then it cannot tell whether it would
# step backwards. Not run in a subshell.
live_tag() {
  local code tag
  live=""
  code=$(get "deploy-stamp.txt?run=${GITHUB_RUN_ID:-0}" live-stamp.txt)
  case $code in
    404) : > live-stamp.txt; return ;;
    200) ;;
    *) [ "${ALLOW_OLDER:-}" = true ] && { : > live-stamp.txt; return; }
       skip "not deployed: $site/deploy-stamp.txt answered $code, so this run cannot tell which packages it would replace" warn ;;
  esac
  tag=$(sed -n 's/^packages \([^ ]*\).*$/\1/p' live-stamp.txt | head -n 1)
  if [ "$tag" != none ] && ! [[ "$tag" =~ ^v[0-9A-Za-z.+-]+$ ]]; then
    [ "${ALLOW_OLDER:-}" = true ] && { : > live-stamp.txt; return; }
    skip "not deployed: $site/deploy-stamp.txt names no packages tag, so this run cannot tell which packages it would replace" warn
  fi
  live=$tag
}

# Whether zigbox.org serves the live stamp's signed files: compares each against its `file` line.
# Prints the first difference and returns 1, or returns 0.
served_as_stamped() {
  local f want code got
  for f in "${signed[@]}"; do
    want=$(awk -v p="$f" '$1 == "file" && $3 == p { print $2; exit }' live-stamp.txt)
    if [ -z "$want" ]; then
      echo "the live stamp has no sha256 for /$f"
      return 1
    fi
    code=$(get "$f" got.tmp)
    got=$(sha256sum got.tmp | cut -d' ' -f1)
    if [ "$code" != 200 ] || [ "$got" != "$want" ]; then
      echo "/$f answered $code with sha256 $got, the live stamp says $want"
      return 1
    fi
  done
  rm -f got.tmp
}

gate() {
  if [ "$EVENT" = schedule ] && [ "${HAVE_CF:-}" != true ]; then
    skip "not deployed: the CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID secrets are not set" warn
  fi
  local box cube pick tag="" id="" sum="" deploy=true why
  box=${GATE_BOX:-$(gh api repos/ZigboxOrg/zigbox/commits/main --jq .sha)}
  cube=${GATE_CUBE:-$(gh api repos/ZigboxOrg/zigcube/commits/main --jq .sha)}
  if [ -n "${GATE_RELEASES:-}" ]; then
    cp "$GATE_RELEASES" releases.json
  else
    gh api --paginate --slurp 'repos/ZigboxOrg/zigbox/releases?per_page=100' > releases.json
  fi
  live_tag
  pick=$(jq -r --arg asset "$asset" --arg live "$live" -f "$here/pick-release.jq" releases.json)
  if [[ "$pick" == gone* ]] && [ "${ALLOW_OLDER:-}" = true ]; then
    echo "packages: $live is no longer a published release; allow_older_packages takes the newest"
    pick=$(jq -r --arg asset "$asset" --arg live "" -f "$here/pick-release.jq" releases.json)
  fi
  case $pick in
    "take "*) read -r _ tag id sum <<< "$pick" ;;
    none) ;;
    "wait "*) skip "not deployed: zigbox.org serves $live, whose $asset is not uploaded right now (a refresh replacing it, or an upload in progress), and only a newer release may replace it; the next run takes it" ;;
    "gone "*) skip "not deployed: zigbox.org serves $live, which is no longer a published release, and no newer release carries $asset; only the owner may step back (workflow_dispatch with allow_older_packages)" warn ;;
    *) echo "packages: pick-release.jq printed '$pick'"; exit 1 ;;
  esac
  sum=${sum#sha256:}
  if [ -n "$tag" ] && [ -z "$sum" ]; then
    # An asset without the API's digest: hash it here (a few MB).
    sum=$(gh api -H 'Accept: application/octet-stream' \
      "repos/ZigboxOrg/zigbox/releases/assets/$id" | sha256sum | cut -d' ' -f1)
  fi
  {
    echo "site $SELF_SHA"
    echo "zigbox $box"
    echo "zigcube $cube"
    if [ -n "$tag" ]; then echo "packages $tag sha256:$sum"; else echo "packages none"; fi
  } > stamp-core.txt
  cat stamp-core.txt
  printf '%s\n' "box=$box" "cube=$cube" "tag=$tag" "asset_id=$id" "sum=$sum" >> "$out"
  if [ "$EVENT" = schedule ]; then
    if ! grep -v '^file ' live-stamp.txt | cmp -s - stamp-core.txt; then
      echo "changed: zigbox.org's stamp differs, so this run deploys"
    elif [ -n "$tag" ] && ! why=$(served_as_stamped); then
      echo "changed: $why, so this run deploys"
    else
      echo "unchanged: zigbox.org serves this stamp and its signed files, so this run deploys nothing"
      deploy=false
    fi
  else
    echo "deploy: a $EVENT run always builds, whatever zigbox.org serves"
  fi
  echo "deploy=$deploy" >> "$out"
}

# Checks the signatures of the unpacked tree in $1 against the pinned owner key; prints one line
# and returns 1 on any failure.
owner_signed() {
  local tree=$1 g fprs f sig
  g=$(mktemp -d)
  for f in zigbox-archive-keyring.gpg zigbox-archive-keyring.asc; do
    fprs=$(GNUPGHOME=$g gpg --batch --show-keys --with-colons "$tree/$f" 2> /dev/null |
      awk -F: '$1 == "pub" { p = 1; next } $1 == "fpr" && p { print $10; p = 0 }')
    if [ "$fprs" != "$owner_key" ]; then
      echo "packages: $f holds the primary key(s) '${fprs//$'\n'/ }', not the owner's $owner_key"
      rm -rf "$g"
      return 1
    fi
  done
  for sig in apt/dists/stable/InRelease apt/dists/stable/Release.gpg \
    rpm/x86_64/repodata/repomd.xml.asc rpm/aarch64/repodata/repomd.xml.asc; do
    f=()
    case $sig in
      *.gpg) f=("$tree/${sig%.gpg}") ;;
      *.asc) f=("$tree/${sig%.asc}") ;;
    esac
    # VALIDSIG's last field is the signing key's primary fingerprint.
    if ! GNUPGHOME=$g gpgv --status-fd 1 --keyring "$tree/zigbox-archive-keyring.gpg" \
      "$tree/$sig" "${f[@]}" 2> /dev/null | grep -q "^\[GNUPG:\] VALIDSIG .* $owner_key\$"; then
      echo "packages: $sig is not a good signature by the owner's key $owner_key"
      rm -rf "$g"
      return 1
    fi
  done
  rm -rf "$g"
}

packages() {
  mkdir -p pkg
  if [ -z "${TAG:-}" ]; then
    echo "packages: no ZigboxOrg/zigbox release carries $asset yet, so /apt and /rpm are not deployed"
    cp stamp-core.txt stamp.txt
    echo "go=true" >> "$out"
    return
  fi
  # The exact asset the stamp names (by id), through the REST API. A refresh may replace it
  # between the gate and here: then this run stops cleanly and the next one takes the new asset.
  if ! gh api -H 'Accept: application/octet-stream' \
    "repos/ZigboxOrg/zigbox/releases/assets/$ASSET_ID" > "pkg/$asset" 2> pkg/err; then
    echo "not deployed: $asset of $TAG was replaced during this run ($(head -c 200 pkg/err | tr '\n' ' ')); the next run deploys the new one"
    return
  fi
  local got f big
  got=$(sha256sum "pkg/$asset" | cut -d' ' -f1)
  if [ "$got" != "$SUM" ]; then
    echo "not deployed: $asset of $TAG changed during this run (sha256 $got, stamp $SUM); the next run deploys it"
    return
  fi
  # Only regular files and directories under apt/ and rpm/, and the two keyring files.
  # No dot files (the assembly deletes them), no .html (the Worker's auto-trailing-slash
  # would redirect it), no white space, never the test key or the to-sign list.
  tar -tvzf "pkg/$asset" | awk '{ print substr($1, 1, 1) }' | sort -u > pkg/kinds
  if grep -qvx -e - -e d pkg/kinds; then
    echo "packages: $asset of $TAG holds something other than files and directories"
    exit 1
  fi
  tar -tzf "pkg/$asset" | sed 's|^\./||' | grep -v '^$' > pkg/list
  if grep -vE '^(apt/|rpm/|zigbox-archive-keyring\.(gpg|asc)$)' pkg/list ||
    grep -E '(^|/)\.|\.html?$|[[:space:]]|to-sign|zigbox-test-key' pkg/list; then
    echo "packages: $asset of $TAG holds the paths above, which zigbox.org must not serve"
    exit 1
  fi
  mkdir pkg/tree
  tar -xzf "pkg/$asset" -C pkg/tree --no-same-owner --no-same-permissions
  for f in "${signed[@]}"; do
    test -s "pkg/tree/$f" || { echo "packages: $f is missing from $asset of $TAG"; exit 1; }
  done
  owner_signed pkg/tree || exit 1
  # Workers static assets refuse a file over 25 MiB.
  big=$(find pkg/tree -type f -size +25M)
  if [ -n "$big" ]; then echo "packages: over 25 MiB, which the Worker cannot serve: $big"; exit 1; fi
  (cd pkg/tree && find . -type f -print0 | sort -z | xargs -0 sha256sum | sed 's|  \./|  |') \
    > pkg/manifest
  {
    cat stamp-core.txt
    for f in "${signed[@]}"; do echo "file $(sha256sum < "pkg/tree/$f" | cut -d' ' -f1) $f"; done
  } > stamp.txt
  echo "packages: $(wc -l < pkg/manifest) files from $asset of Zigbox $TAG, signed by $owner_key"
  echo "go=true" >> "$out"
}

check() {
  # The stamp is checked too: the next scheduled run skips the deploy only when it matches.
  {
    if [ -f pkg/manifest ]; then cat pkg/manifest; fi
    echo "$(sha256sum < stamp.txt | cut -d' ' -f1)  deploy-stamp.txt"
  } > served
  if [ ! -f pkg/manifest ]; then echo "packages: none deployed, checking the stamp alone"; fi
  # No redirect followed and no decoding: a 3xx, a rewrite or a Content-Encoding the asset did
  # not have all show as a status or digest mismatch. The edge may serve the previous release's
  # Release or InRelease for a short while, so retry before failing.
  local attempt bad sum path code got
  for attempt in 1 2 3 4 5 6; do
    bad=0
    while read -r sum path; do
      code=$(get "$path" got.tmp)
      got=$(sha256sum got.tmp | cut -d' ' -f1)
      if [ "$code" != 200 ] || [ "$got" != "$sum" ]; then
        echo "check $attempt: /$path served $code, sha256 $got; expected $sum"
        bad=1
      fi
    done < served
    if [ "$bad" = 0 ]; then
      echo "served: $site serves all $(wc -l < served) checked files unchanged"
      return
    fi
    sleep "${CHECK_SLEEP:-20}"
  done
  echo "not served: $site does not serve the repositories and the stamp as deployed"
  exit 1
}

case ${1:-} in
  gate) gate ;;
  packages) packages ;;
  check) check ;;
  verify) owner_signed "${2:?usage: deploy.sh verify TREE}" && echo "packages: $2 is signed by $owner_key" ;;
  *) echo "usage: deploy.sh gate|packages|check|verify TREE" >&2; exit 64 ;;
esac
