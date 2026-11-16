#!/bin/bash
# Run as an app build phase. Owner installs fail closed if a command-line override drops the flag.
set -euo pipefail
has_owner=0
for condition in ${SWIFT_ACTIVE_COMPILATION_CONDITIONS:-} ${OTHER_SWIFT_FLAGS:-}; do
    # Swift accepts both -D NAME and -DNAME through OTHER_SWIFT_FLAGS.
    condition=${condition#-D}
    if [ "$condition" = ILYICH_OWNER_BUILD ]; then has_owner=1; fi
done
if [ "${CONFIGURATION:-}" = Owner ] && [ "$has_owner" = 0 ]; then
    echo 'error: Owner builds require ILYICH_OWNER_BUILD. Remove the compilation-condition override.' >&2
    exit 1
fi
if [ "${CONFIGURATION:-}" = Release ] && [ "$has_owner" = 1 ]; then
    echo 'error: Release builds cannot contain the owner unlock. Use the IlyichOwner scheme for local installs.' >&2
    exit 1
fi
