if contains("\n  APP_IDS: |\n") then
  split("\n  APP_IDS: |\n")[1] | split("\n") | [foreach .[] as $line (true; . and ($line | startswith("    ")); if . then $line[4:] else empty end)]
else split("\n") | if .[-1] == "" then .[:-1] else . end end |
if length > 0 and all(.[]; test("^[1-9][0-9]*$"))
then
  if (unique | length) == length then map(tonumber)
  else error("expected unique App Store IDs") end
else error("expected positive integer App Store IDs, one per line") end
