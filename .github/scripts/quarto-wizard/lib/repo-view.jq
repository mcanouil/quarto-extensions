# Shape a `gh repo view` payload into the record stored as extension.json.
#
# Used by both the batched prefetch and the inline fallback in extension.sh, so
# a record is identical whichever path produced it.
{
  name: .name,
  title: (.name | split("-|_"; "") | map(select(. != "quarto" and . != "template")) | join(" ") | ascii_upcase),
  nameWithOwner: (.nameWithOwner | ascii_downcase),
  owner: (.owner.login | ascii_downcase),
  description: (if .description == "" then "No description available." else .description end),
  openGraphImageUrl: .openGraphImageUrl,
  stargazerCount: (.stargazerCount // 0),
  licenseInfo: (.licenseInfo.name // "none"),
  url: .url,
  latestRelease: (.latestRelease.tagName // "none"),
  latestReleaseUrl: (.latestRelease.url // null),
  createdAt: .createdAt,
  updatedAt: .updatedAt,
  pushedAt: .pushedAt,
  defaultBranchRef: .defaultBranchRef.name,
  repositoryTopics: (if .repositoryTopics == null then [] else
  [.repositoryTopics[].name |
    sub("^quarto-"; "") |
    sub("-template[s]*"; "") |
    if test("filters$|formats$|journals$|templates|shortcodes$|extensions$") then sub("s$"; "") else . end |
    sub("reveal-js"; "reveal.js") |
    sub("revealjs"; "reveal.js") |
    select(test("quarto|extension|template|^pub$") | not)] | unique
  end)
}
