# Picks the release whose zigbox-repos.tar.gz zigbox.org should serve, never stepping backwards.
# Input: `gh api --paginate --slurp .../releases` (an array of pages). Arguments: $asset, the
# asset's name; $live, the tag the live /deploy-stamp.txt names ("" when zigbox.org has no stamp,
# or a push or dispatch could not read it; "none" when it serves no packages); $live_created, the
# live tag's created_at as that stamp records it ("" when it records none). Prints one line:
#   take TAG ID CREATED DIGEST  deploy this asset (DIGEST is the API's "sha256:...", or empty)
#   none                 no published release exists (live ""), or none carries the asset and
#                        zigbox.org serves no packages either (live "none")
#   wait TAG             the release that may be deployed next is TAG, but its asset is not
#                        `uploaded` right now (a refresh's --clobber, or an upload in progress):
#                        deploy nothing, the next run takes it
#   gone TAG             zigbox.org serves TAG, TAG is no longer a published release, and no
#                        published release was created after it: deploy nothing until the owner
#                        decides
# A published release is one that is not a draft and not a prerelease; a candidate is a published
# release carrying the asset in state `uploaded` (any other state counts as not there yet). The
# newest is the latest created_at; the API's order is never trusted.
#   live "":     the newest published release, if it is a candidate; else wait for it. Never an
#                older release, as zigbox.org may serve packages no stamp names.
#   live "none": the newest candidate, else none.
#   live TAG:    the newest candidate that is TAG itself or was created after TAG (by the
#                release's created_at, or the stamp's when the release was deleted); else wait
#                for the newest such published release; else gone. A deleted release whose
#                stamp records no created_at cannot be ordered: gone.
[.[][]] as $all
| [$all[] | select(.draft == false and .prerelease == false)
    | {tag: .tag_name, created: .created_at, up: ([.assets[]?
        | select(.name == $asset and .state == "uploaded")] | .[0])}] as $pub
| def newest: sort_by(.created) | last;
  def pick: if . == null then null
    elif .up == null then "wait \(.tag)"
    else "take \(.tag) \(.up.id) \(.created) \(.up.digest // "")" end;
  if $live == "" then
    ($pub | newest | pick) // "none"
  elif $live == "none" then
    ([$pub[] | select(.up != null)] | newest | pick) // "none"
  else
    (([$all[] | select(.tag_name == $live)] | .[0].created_at) // $live_created) as $floor
    | if $floor == "" then "gone \($live)"
      else
        [$pub[] | select(.tag == $live or .created > $floor)] as $ok
        | ([$ok[] | select(.up != null)] | newest | pick) // ($ok | newest | pick)
          // "gone \($live)"
      end
  end
