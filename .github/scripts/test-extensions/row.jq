# Encode an array of fields as one line for `IFS=$'\x1f' read -r`.
#
# The ASCII unit separator is used rather than a tab. A tab is IFS whitespace,
# so read merges empty fields and shifts every later value into the wrong
# variable; a non-whitespace separator keeps each empty field in its place.
# Unlike @tsv, nothing is escaped, so a backslash reads back as itself. A null
# becomes an empty field, and a newline or separator inside a value becomes a
# space, so that each row stays on one line.
def row: map(. // "" | tostring | gsub("[\n\r\u001f]"; " ")) | join("\u001f");
