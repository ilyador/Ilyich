#!/bin/bash
# Build and install an owner app over the existing app, without changing its data or launching it.
# Uses cached signing assets; unlock the signing keychain before running, when required.
set -euo pipefail
if [ "$#" != 3 ]; then
    echo "usage: $0 <version> <build> <device-id>" >&2
    exit 2
fi
version=$1
build_number=$2
device=$3
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$build_number" =~ ^[1-9][0-9]*$ ]] || {
    echo 'Supply a numeric x.y.z version and a positive integer build number.' >&2; exit 2;
}
[ "$(uname -s)" = Darwin ] || { echo 'Run this script on the signing Mac.' >&2; exit 2; }
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
native_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$native_root"
xcodegen generate
# The macOS system Bash treats an empty array as unset under `set -u`.
# Keep the required signing flag in the array alongside optional signing arguments.
signing_arguments=("CODE_SIGNING_ALLOWED=YES")
if [ -n "${SIGNING_KEYCHAIN:-}" ]; then
    signing_arguments+=("OTHER_CODE_SIGN_FLAGS=--keychain $SIGNING_KEYCHAIN")
fi
derived="$native_root/build/Owner-$build_number"
xcrun xcodebuild build -project Ilyich.xcodeproj -scheme IlyichOwner -configuration Owner \
    -destination "id=$device" -derivedDataPath "$derived" -jobs 3 \
    DEVELOPMENT_TEAM="${TEAM_ID:-H4K2MSF2SG}" CODE_SIGN_STYLE=Automatic \
    MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build_number" "${signing_arguments[@]}"
app="$derived/Build/Products/Owner-iphoneos/Ilyich.app"
executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Info.plist")
has_owner=0
# Debug configurations may place Swift code in the debug dylib, rather than the launcher binary.
for binary in "$app/$executable" "$app/$executable.debug.dylib"; do
    [ -f "$binary" ] || continue
    if /usr/bin/nm -j "$binary" | /usr/bin/grep -F OwnerPurchaseClient >/dev/null; then
        has_owner=1
    fi
done
[ "$has_owner" = 1 ] || { echo 'Refusing to install: the built app has no owner-access client.' >&2; exit 1; }
/usr/bin/codesign --verify --deep --strict "$app"
xcrun devicectl device install app --device "$device" "$app"
