#!/bin/bash
# Builds the release downloads for both kinds of Mac into dist/:
#   FlightCore-OSX-<version>-arm64.zip    Apple silicon
#   FlightCore-OSX-<version>-x86_64.zip   Intel
set -euo pipefail
cd "$(dirname "$0")"
VERSION="$(grep '^VERSION=' build_app.sh | cut -d'"' -f2)"
rm -rf dist
for ARCH in arm64 x86_64; do
    ./build_app.sh "$ARCH" "dist/$ARCH"
    ditto -c -k --keepParent "dist/$ARCH/FlightCore.app" "dist/FlightCore-OSX-$VERSION-$ARCH.zip"
    echo "dist/FlightCore-OSX-$VERSION-$ARCH.zip  ($(lipo -archs "dist/$ARCH/FlightCore.app/Contents/MacOS/FlightCore"))"
done
