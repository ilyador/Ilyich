#!/bin/bash
# One upload engine at a time (REBUILD_ROADMAP.md, B5 to B10). Runs before every build of the app.
#
# iOS allows one URLSession per background identifier in a process; a second session with the same
# identifier gets undefined event delivery. From the cutover (B9) the transfer engine runs backup,
# and today's BackgroundUploads stays only as the way back for an account whose backup records
# couldn't be imported, until B10 deletes it. TransferHost chooses one of them per process and
# starts only that one. The build fails when
#   1. a background session is configured anywhere but TransferSessionConfiguration.swift;
#   2. a session is built from that configuration anywhere but BackgroundUploads (the way back,
#      until B10) and the new transport's live session;
#   2b. code names BackgroundUploads anywhere but the old engine's own files and TransferHost,
#      which starts it only when the process runs the old engine;
#   3. app or extension code outside Sources/Transfers names the new transport's types: only
#      TransferHost creates the sessions and takes iOS's completion handlers;
#   3b. code outside Sources/Transfers names the new lifecycle's types: iOS allows one launch
#      handler per background task identifier, which TransferHost's router registers;
#   3c. code outside Sources/Transfers names the post-upload work, share jobs or notifier, which
#      only an account's TransferRuntime runs.
#
# One door to Photos as well (REBUILD_ROADMAP.md, P1). The build also fails when code outside
# Sources/Device
#   4. observes the Photos library, rather than subscribing to PhotoKitAdapter.changes();
#   5. changes the library, rather than through PhotoKitAdapter.perform, which journals each change
#      and checks it again inside its change block;
#   6. fetches assets or requests their media itself, rather than through the adapter's reads and
#      its one shared image manager (P3).
set -eo pipefail
cd "$(dirname "$0")/.."

roots=(Sources Extensions Packages)
configuration=Sources/Transfers/TransferSessionConfiguration.swift
session_builders=(Sources/Backup/BackgroundUploads.swift Sources/Transfers/TransportSession.swift)
# The old engine's files, and the host that starts it only when the process runs it.
legacy_engine=(Sources/Backup/BackgroundUploads.swift Sources/Backup/BackupCoordinator.swift Sources/Backup/BackupLifecycle.swift
               Sources/Backup/ShareInboxStore.swift Sources/Transfers/TransferHost.swift)
# The transport's types that open a session or take over iOS's completion handlers. Its value
# types and the TransferTransport protocol may be named anywhere.
transport_types='TransportRegistry|BackgroundTransport|BackgroundEventAcks|URLSessionTransportSession|BackgroundSessionDelegate|TransportEventProcessor'
# The lifecycle's types that register background tasks or drive backup's background time.
lifecycle_types='LifecycleEventSource|SystemBackgroundTaskScheduler|SystemLifecycleInputs|SystemBackgroundTime|TransferLifecycle'
# The post-upload work, share jobs and notifications that run beside the engine (B4).
followup_types='PostUploadWorker|ShareJobExecutor|LaneJobExecutor|TransferNotifier|SystemTransferNotificationPoster'

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
reject "only BackgroundUploads (the way back, until B10) and the transport's live session may build a background session" \
    "${session_builders[@]}" < <(code_lines 'TransferSessionConfiguration\.make\(')
reject "only TransferHost starts the old engine's sessions, and only when the process runs it; use BackupStore or TransferHost" \
    "${legacy_engine[@]}" < <(code_lines -w 'BackgroundUploads')
reject "only TransferHost creates the transport and takes iOS's completion handlers" \
    < <(code_lines -w "$transport_types" | grep -v '^Sources/Transfers/' || true)
reject "only TransferHost registers the background tasks and runs the lifecycle; iOS allows one handler each" \
    < <(code_lines -w "$lifecycle_types" | grep -v '^Sources/Transfers/' || true)
reject "only an account's TransferRuntime runs the post-upload work, share jobs and notifier" \
    < <(code_lines -w "$followup_types" | grep -v '^Sources/Transfers/' || true)
reject "only the Photos adapter in Sources/Device observes the library; subscribe to PhotoKitAdapter.changes()" \
    < <(code_lines 'PHPhotoLibraryChangeObserver|unregisterChangeObserver|PHPhotoLibrary\.shared\(\)\.register\(' | grep -v '^Sources/Device/' || true)
reject "only the Photos adapter in Sources/Device changes the library; use PhotoKitAdapter.perform, which journals the change" \
    < <(code_lines 'performChanges|PHAssetChangeRequest|PHAssetCreationRequest|PHAssetCollectionChangeRequest|PHCollectionListChangeRequest' | grep -v '^Sources/Device/' || true)
reject "only the Photos adapter in Sources/Device fetches assets or requests their media; use its reads and PhotoKitAdapter.media" \
    < <(code_lines 'PHImageManager|PHCachingImageManager|PHAsset\.fetchAssets' | grep -v '^Sources/Device/' || true)

if [ "$failures" -gt 0 ]; then
    echo "check-single-engine: $failures problem(s); see REBUILD_ROADMAP.md, B4, B5, B7, B9, B10, P1 and P3" >&2
    exit 1
fi
