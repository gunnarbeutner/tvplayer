#!/usr/bin/env bash

set -euo pipefail

configuration="${1:-Debug}"
derived_data=".build/DerivedData-Multiplatform"

bash Scripts/install-vlckit.sh
xcodegen generate

xcodebuild \
  -project TVApp.xcodeproj \
  -scheme TVApp \
  -sdk appletvos \
  -configuration "$configuration" \
  -derivedDataPath "$derived_data/tvOS" \
  CODE_SIGNING_ALLOWED=NO \
  build

xcodebuild \
  -project TVApp.xcodeproj \
  -scheme TVApp-iOS \
  -sdk iphoneos \
  -configuration "$configuration" \
  -derivedDataPath "$derived_data/iOS" \
  CODE_SIGNING_ALLOWED=NO \
  build

xcodebuild \
  -project TVApp.xcodeproj \
  -scheme TVApp-macOS \
  -configuration "$configuration" \
  -derivedDataPath "$derived_data/macOS" \
  CODE_SIGNING_ALLOWED=NO \
  build
