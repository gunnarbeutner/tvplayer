#!/usr/bin/env bash

set -euo pipefail

configuration="${1:-Debug}"
derived_data=".build/DerivedData-Multiplatform"

bash Scripts/install-vlckit.sh
xcodegen generate

xcodebuild \
  -project TVPlayer.xcodeproj \
  -scheme TVPlayer \
  -sdk appletvos \
  -configuration "$configuration" \
  -derivedDataPath "$derived_data/tvOS" \
  CODE_SIGNING_ALLOWED=YES \
  build

xcodebuild \
  -project TVPlayer.xcodeproj \
  -scheme TVPlayer-iOS \
  -sdk iphoneos \
  -configuration "$configuration" \
  -derivedDataPath "$derived_data/iOS" \
  CODE_SIGNING_ALLOWED=YES \
  build

xcodebuild \
  -project TVPlayer.xcodeproj \
  -scheme TVPlayer-macOS \
  -configuration "$configuration" \
  -derivedDataPath "$derived_data/macOS" \
  CODE_SIGNING_ALLOWED=YES \
  build
