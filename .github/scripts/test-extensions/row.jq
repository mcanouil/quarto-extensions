# Encode an array of fields as one line for `IFS=$'\x1f' read -r`.
#
# The ASCII unit separator is used rather than a tab. A tab is IFS whitespace,
# so read merges empty fields and shifts every later value into the wrong
# variable; a non-whitespace separator keeps each empty field in its place.
# Unlike @tsv, nothing is escaped, so a backslash reads back as itself. Only a
# null becomes an empty field; false and numbers read back as text. A newline or
# separator inside a value becomes a space, so that each row stays on one line.
def row: map(if . == null then "" else tostring end | gsub("[\n\r\u001f]"; " ")) | join("\u001f");
