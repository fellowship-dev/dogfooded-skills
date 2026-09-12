#!/usr/bin/env bash
set -euo pipefail

# Emit every issue-link keyword with its issue number and complete source line.
# Keeping the source line lets the reviewer distinguish a driving issue from
# references that the author explicitly labels as related context.
awk '
{
  line = $0
  rest = $0
  while (match(rest, /(Closes|Fixes|Resolves|Refs)[[:space:]]+#[0-9]+/)) {
    link = substr(rest, RSTART, RLENGTH)
    keyword = link
    sub(/[[:space:]].*$/, "", keyword)
    issue = link
    sub(/^.*#/, "", issue)
    printf "%s\t%s\t%s\n", keyword, issue, line
    rest = substr(rest, RSTART + RLENGTH)
  }
}
' "${1:-/dev/stdin}"
