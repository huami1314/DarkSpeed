#!/bin/sh

set -eu

version=$(./get-version.sh)
archive_path="${DARKSPEED_ARCHIVE_PATH:-$PWD/DarkSpeed.xcarchive}"
package_dir="$PWD/packages"
package_path="$package_dir/DarkSpeed_${version}.ipa"
temporary_dir=$(mktemp -d)

cleanup() {
    rm -rf "$temporary_dir"
}
trap cleanup EXIT INT TERM

set -- clean build archive \
    -scheme DarkSpeed \
    -project DarkSpeed.xcodeproj \
    -configuration Release \
    -sdk iphoneos \
    -destination 'generic/platform=iOS' \
    -archivePath "$archive_path" \
    -xcconfig supports/darksword.xcconfig \
    PRODUCT_BUNDLE_IDENTIFIER=com.huami.darkspeed \
    CODE_SIGN_ENTITLEMENTS=supports/entitlements-darksword.plist \
    IPHONEOS_DEPLOYMENT_TARGET=16.0

if [ "${DARKSPEED_UNSIGNED:-0}" = "1" ]; then
    set -- "$@" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
fi

echo "Building DarkSpeed $version"
xcodebuild "$@"

application_path="$archive_path/Products/Applications/DarkSpeed.app"
if [ ! -d "$application_path" ]; then
    echo "Archive does not contain DarkSpeed.app" >&2
    exit 1
fi

mkdir -p "$temporary_dir/Payload" "$package_dir"
cp -R "$application_path" "$temporary_dir/Payload/DarkSpeed.app"
(cd "$temporary_dir" && /usr/bin/zip -qry "$package_path" Payload)

if [ "${DARKSPEED_UNSIGNED:-0}" = "1" ]; then
    echo "Wrote $package_path (unsigned; sign it before installation)"
else
    echo "Wrote $package_path"
fi
