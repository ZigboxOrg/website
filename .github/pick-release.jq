# Picks the release whose zigbox-repos.tar.gz zigbox.org should serve, never stepping backwards.
# Input: `gh api --paginate --slurp .../releases` (an array of pages). Arguments: $asset, the
# asset's name; $live, the tag the live /deploy-stamp.txt names ("" when zigbox.org has no stamp,
# "none" when it serves no packages). Prints one line:
#   take TAG ID DIGEST   deploy this asset (DIGEST is the API's "sha256:...", or empty)
#   none                 no release carries the asset, and zigbox.org serves no packages either
#   wait TAG             zigbox.org serves TAG, no newer release carries the asset, and TAG's
#                        asset is not `uploaded` right now (a refresh's --clobber, or an upload
#                        in progress): deploy nothing, the next run takes it
#   gone TAG             zigbox.org serves TAG, but TAG is no longer a published release and no
#                        newer one carries the asset: deploy nothing until the owner decides
# A candidate is a release that is not a draft, not a prerelease and carries the asset in state
# `uploaded` (any other state counts as not there yet). The newest is the latest created_at.
# Only the live tag itself, or a candidate created after it, may be deployed.
[.[][]] as $all
| [$all[] | select(.draft == false and .prerelease == false) | . as $r
    | .assets[]? | select(.name == $asset and .state == "uploaded")
    | {tag: $r.tag_name, created: $r.created_at, id, digest: (.digest // "")}] as $cands
| def take: if . == null then null else "take \(.tag) \(.id) \(.digest)" end;
  if $live == "" or $live == "none" then
    ($cands | sort_by(.created) | last | take) // "none"
  else
    ($all | map(select(.tag_name == $live)) | .[0]) as $l
    | if $l == null then "gone \($live)"
      else
        ([$cands[] | select(.tag == $live or .created > $l.created_at)]
          | sort_by(.created) | last | take)
        // (if $l.draft or $l.prerelease then "gone \($live)" else "wait \($live)" end)
      end
  end
