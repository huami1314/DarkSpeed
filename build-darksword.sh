#!/bin/sh
# Build TrollSpeed with the DarkSword bridge enabled.
# All required DarkSword sources and libraries are vendored in this repository.

set -e
cd "$(dirname "$0")"

VERSION=$(./get-version.sh) || exit 1
echo "Building TrollSpeed+DarkSword version: $VERSION"

if [ ! -d Vendor/darksword-kexploit ]; then
  echo "Vendor/darksword-kexploit is missing" >&2
  exit 1
fi

if [ -z "$GITHUB_WORKSPACE" ]; then
  GITHUB_WORKSPACE="$HOME"
fi
THEOS="${THEOS:-$GITHUB_WORKSPACE/theos-roothide}"
if [ ! -d "$THEOS" ]; then
  THEOS="$GITHUB_WORKSPACE/theos"
fi

echo "THEOS=$THEOS"

xcodebuild clean build archive \
  -scheme TrollSpeed \
  -project TrollSpeed.xcodeproj \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -archivePath TrollSpeed-DarkSword \
  -xcconfig supports/darksword.xcconfig \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGN_STYLE=Automatic \
  DEVELOPMENT_TEAM=6LMF23FAGL \
  PRODUCT_BUNDLE_IDENTIFIER=com.huami.respring \
  CODE_SIGN_ENTITLEMENTS=supports/entitlements-darksword.plist \
  IPHONEOS_DEPLOYMENT_TARGET=16.0 \
  THEOS="$THEOS"

mkdir -p packages
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/trollspeed-darksword.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
cp -R TrollSpeed-DarkSword.xcarchive/Products/Applications "$STAGE/Payload"
OUTPUT="$(pwd)/packages/TrollSpeed+DarkSword_$VERSION.ipa"
(cd "$STAGE" && zip -qry "$OUTPUT" Payload)
echo "Wrote $OUTPUT (Apple Development signed)"
