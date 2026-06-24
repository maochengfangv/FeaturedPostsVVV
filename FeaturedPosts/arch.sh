#!/usr/bin/env bash
set -euo pipefail

WORKSPACE="FeaturedPosts.xcworkspace"
SCHEME="FeaturedPosts"
DEST="platform=iOS Simulator,name=iPhone 16"

MODE="${1:-debug}"
if [[ "$MODE" == "release" ]]; then
  CONFIG="Release"
else
  CONFIG="Debug"
fi

xcodebuild \
  -workspace "$WORKSPACE" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -destination "$DEST" \
  clean build

xcodebuild \
  -workspace "$WORKSPACE" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -destination "$DEST" \
  test