#!/bin/bash
# One upload engine at a time (REBUILD_ROADMAP.md, B5 to B9). Runs before every build of the app.
#
# iOS allows one URLSession per background identifier in a process; a second session with the same
# identifier gets undefined event delivery. Until the cutover (B9), today's BackgroundUploads is
# the only engine that runs, and the new transport in Sources/Transfers stays dormant: compiled
# and tested with fakes, never created by the app. The build fails when
#   1. a background session is configured anywhere but TransferSessionConfiguration.swift;
#   2. a session is built from that configuration anywhere but today's BackgroundUploads
#      (allowed until B9) and the new transport's live session;
#   3. app or extension code outside Sources/Transfers names the new transport's types, which would
#      start it beside BackgroundUploads, or hand it today's completion handlers, before B9.
# B9 deletes BackgroundUploads from rule 2's list and drops rule 3, and adds the old engine's
# symbols, which must then be gone.
set -eo pipefail
cd "$(dirname "$0")/.."

roots=(Sources Extensions Packages)
configuration=Sources/Transfers/TransferSessionConfiguration.swift
session_builders=(Sources/Backup/BackgroundUploads.swift Sources/Transfers/TransportSession.swift)
# The transport's types that open a session or take over iOS's completion handlers. Its value
# types and the TransferTransport protocol may be named anywhere.
transport_types='TransportRegistry|BackgroundTransport|BackgroundEventAcks|URLSessionTransportSession|BackgroundSessionDelegate|TransportEventProcessor'

failures=0

# Swift lines matching a pattern as file:line:text, leaving out lines that are only a comment.
code_lines() {
    grep -rnE --include='*.swift' "$@" "${roots[@]}" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*(//|\*|/\*)' || true
}

# Reports each file:line:text line on stdin whose file is not in the allowed list.
reject() {
    local message=$1; shift
    local file line text allowed
    while IFS=: read -r file line text; do
        [ -n "$file" ] || continue
        for allowed in "$@"; do
            [ "$file" = "$allowed" ] && continue 2
        done
        echo "$PWD/$file:$line: error: $message" >&2
        failures=$((failures + 1))
    done
}

reject "configure background sessions only in $configuration, so no identifier gets two sessions" \
    "$configuration" < <(code_lines '\.background\(withIdentifier:|backgroundSessionConfiguration')
# The one call site must be found, or the check is not reading the sources (a sandboxed build phase).
found=$(code_lines '\.background\(withIdentifier:' | grep -c "^$configuration:" || true)
if [ "$found" -ne 1 ]; then
    echo "$PWD/$configuration:1: error: expected one background configuration here, found $found; is the check able to read the sources?" >&2
    failures=$((failures + 1))
fi
reject "only BackgroundUploads (until B9) and the transport's live session may build a background session" \
    "${session_builders[@]}" < <(code_lines 'TransferSessionConfiguration\.make\(')
reject "the new upload transport stays dormant until B9; the app must not create it beside BackgroundUploads" \
    < <(code_lines -w "$transport_types" | grep -v '^Sources/Transfers/' || true)

if [ "$failures" -gt 0 ]; then
    echo "check-single-engine: $failures problem(s); see REBUILD_ROADMAP.md, B5 and B9" >&2
    exit 1
fi
