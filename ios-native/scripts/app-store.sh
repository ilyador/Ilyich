#!/bin/bash
# Native Ilyich only. Creates a Release archive or exports a local App Store IPA; never uploads.
#
#   scripts/app-store.sh archive 3.3.5 3040108
#   scripts/app-store.sh export build/AppStore/Ilyich-3.3.5-3040108.xcarchive
#
# Automatic signing uses team H4K2MSF2SG. Set ALLOW_PROVISIONING_UPDATES=1 to let Xcode
# create/update signing assets using its configured developer account.
# For manual archives, configure BOTH targets' profiles in Ilyich.xcodeproj first and set
# SIGNING_STYLE=manual; that mode preserves the project's target-specific signing settings.
# For manual export, pass an ExportOptions.plist as the third argument to `export`, with
# signingStyle=manual and provisioningProfiles for io.ilyador.ilyich and
# io.ilyador.ilyich.ShareExtension. No signing credentials belong in this repository.
# SIGNING_KEYCHAIN optionally selects an already-unlocked keychain for codesign.
set -euo pipefail

usage() {
    echo "usage: $0 archive <version> <build> | export <archive-path> [export-options-plist]"
}

action=${1:---help}
if [ "$action" = --help ] || [ "$action" = -h ]; then usage; exit 0; fi
case "$action:$#" in
    archive:3|export:2|export:3) ;;
    *) usage >&2; exit 2 ;;
esac
[ "$(uname -s)" = Darwin ] || { echo 'Run this script on the signing Mac.' >&2; exit 2; }
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
native_root=$(cd "$(dirname "$0")/.." && pwd)
team=${TEAM_ID:-H4K2MSF2SG}
signing_arguments=()
if [ -n "${SIGNING_KEYCHAIN:-}" ]; then
    signing_arguments+=("OTHER_CODE_SIGN_FLAGS=--keychain $SIGNING_KEYCHAIN")
fi
provisioning=
case ${ALLOW_PROVISIONING_UPDATES:-0} in
    0) ;;
    1) provisioning=-allowProvisioningUpdates ;;
    *) echo 'ALLOW_PROVISIONING_UPDATES must be 0 or 1.' >&2; exit 2 ;;
esac
cd "$native_root"

case "$action" in
    archive)
        version=$2
        build_number=$3
        [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$build_number" =~ ^[1-9][0-9]*$ ]] || {
            echo 'Supply a numeric x.y.z version and a positive integer build number.' >&2; exit 2;
        }
        archive="$native_root/build/AppStore/Ilyich-$version-$build_number.xcarchive"
        [ ! -e "$archive" ] || { echo "Archive already exists: $archive" >&2; exit 2; }
        signing=${SIGNING_STYLE:-automatic}
        case "$signing" in
            automatic) signing=Automatic; xcodegen generate ;;
            manual)
                signing=Manual
                [ -d Ilyich.xcodeproj ] || {
                    echo 'Generate Ilyich.xcodeproj and configure both manual profiles in Xcode first.' >&2; exit 2;
                } ;;
            *) echo 'SIGNING_STYLE must be automatic or manual.' >&2; exit 2 ;;
        esac
        xcrun xcodebuild archive -project Ilyich.xcodeproj -scheme Ilyich -configuration Release \
            -destination 'generic/platform=iOS' -archivePath "$archive" \
            -derivedDataPath "$native_root/build/AppStoreDerivedData" -jobs 3 \
            ${provisioning:+"$provisioning"} DEVELOPMENT_TEAM="$team" CODE_SIGN_STYLE="$signing" CODE_SIGNING_ALLOWED=YES \
            MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build_number" "${signing_arguments[@]}"
        # The owner's phone builds skip the paywall (ILYICH_OWNER_BUILD). That must never be archived.
        if /usr/bin/strings -a "$archive/Products/Applications/Ilyich.app/Ilyich" | grep -q OwnerPurchaseClient; then
            rm -rf "$archive"
            echo 'This archive contained the owner unlock and was removed. Archive without ILYICH_OWNER_BUILD.' >&2
            exit 1
        fi
        echo "Archive: $archive"
        ;;
    export)
        archive=$2
        options=${3:-"$native_root/Config/AppStoreExportOptions.plist"}
        [ -d "$archive" ] && [ -f "$options" ] || { echo 'Archive and export options must exist.' >&2; exit 2; }
        app="$archive/Products/Applications/Ilyich.app"
        bundle=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")
        share=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/PlugIns/ShareExtension.appex/Info.plist")
        [ "$bundle" = io.ilyador.ilyich ] && [ "$share" = io.ilyador.ilyich.ShareExtension ] || {
            echo 'Only a native Ilyich archive with its Share extension can be exported.' >&2; exit 2;
        }
        /usr/bin/plutil -lint "$options" >/dev/null
        destination=$(/usr/libexec/PlistBuddy -c 'Print :destination' "$options")
        method=$(/usr/libexec/PlistBuddy -c 'Print :method' "$options")
        [ "$destination" = export ] && [ "$method" = app-store-connect ] || {
            echo 'Export options must use method=app-store-connect and destination=export; uploads are not supported.' >&2; exit 2;
        }
        export_path="${archive%.xcarchive}-export"
        [ ! -e "$export_path" ] || { echo "Export path already exists: $export_path" >&2; exit 2; }
        # Xcode's system rsync can find its peer through PATH. Keep Apple tools first so a
        # Homebrew rsync does not reject the system client's extended-attributes flags.
        PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH" xcrun xcodebuild -exportArchive -archivePath "$archive" -exportPath "$export_path" \
            -exportOptionsPlist "$options" ${provisioning:+"$provisioning"}
        echo "Local App Store export: $export_path"
        ;;
esac
