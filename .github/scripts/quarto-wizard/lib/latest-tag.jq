# The rule that picks the latest tag of a repository.
#
# It is the rule of resolveLatestTag in Quarto Wizard
# (packages/core/src/github/latest.ts) for a stable install, so the update
# check gives the same answer with or without a GitHub token. Change both
# together. The registry stores one answer only, so prereleases never qualify.
#
# The input holds the 100 newest releases and the 100 newest tags, as fetched
# by prefetch-repo-info.sh. A higher version outside those windows is missed.
# Quarto Wizard reads up to three pages of 100 releases and of 100 tags, so it
# can see a higher version that the registry misses.

# Normalised stable version of a tag name, as [major, minor, patch], or null.
#
# After one optional leading "v", the name must be a version from start to
# end: one to three numeric parts and optional build metadata. Missing parts
# become zero ("1.2" gives [1, 2, 0]). A prerelease, a leading zero, or a name
# that only contains a version, such as "release-3", gives null.
def stable_version:
  (sub("^\\s+"; "") | sub("\\s+$"; "") | sub("^v"; "")
    | capture("^(?<major>0|[1-9][0-9]*)(?:\\.(?<minor>0|[1-9][0-9]*))?(?:\\.(?<patch>0|[1-9][0-9]*))?(?:\\+[0-9A-Za-z.-]+)?$")
    | [.major, .minor // "0", .patch // "0"] | map(tonumber)
    | select(all(. <= 9007199254740991))) // null;

# Latest tag among the releases and the tags together, as {tagName, url}, or
# null when no tag qualifies.
#
# Input: {releases: [{tagName, url, isPrerelease, isDraft}], tags: [name]}.
# The GitHub "latest release" marker is not used. Drafts are ignored, and a
# tag whose release is flagged as a prerelease does not qualify. Releases come
# first, so a tag of the same version keeps the release URL; a tag without a
# release has a null URL.
def latest_tag:
  [.releases[] | select(.isDraft | not)] as $releases
  | [$releases[] | select(.isPrerelease) | .tagName] as $flagged
  | [($releases[] | {tagName, url}), (.tags[] | {tagName: ., url: null})]
  | map(select(.tagName | IN($flagged[]) | not)
    | . + {version: (.tagName | stable_version)}
    | select(.version != null))
  | reduce .[] as $candidate (null;
      if . == null or $candidate.version > .version then $candidate else . end)
  | if . then {tagName, url} else null end;
