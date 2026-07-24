#!/usr/bin/env bash

set -euo pipefail

mode="${1:-replay}"
simulator="${TVPLAYER_SIMULATOR_ID:-}"

case "$mode" in
  replay|live|all) ;;
  *)
    echo "usage: $0 [replay|live|all]" >&2
    exit 2
    ;;
esac

if [[ -z "$simulator" ]]; then
  simulator="$(
    xcrun simctl list devices booted |
      sed -n 's/.*(\([0-9A-F-]\{36\}\)) (Booted)[[:space:]]*$/\1/p' |
      head -n 1
  )"
fi
if [[ -z "$simulator" ]]; then
  echo "Boot a tvOS simulator or set TVPLAYER_SIMULATOR_ID." >&2
  exit 1
fi

if [[ "$mode" == "live" || "$mode" == "all" ]]; then
  export TVPLAYER_LIVE_TEST_USERNAME="${TVPLAYER_LIVE_TEST_USERNAME:-}"
  export TVPLAYER_LIVE_TEST_HTSP_PORT="${TVPLAYER_LIVE_TEST_HTSP_PORT:-9982}"
  if [[ -n "${TVPLAYER_LIVE_TEST_URL:-}" && -z "${TVPLAYER_LIVE_TEST_PASSWORD:-}" ]]; then
    read -r -s -p "TVHeadend password: " TVPLAYER_LIVE_TEST_PASSWORD
    echo
    export TVPLAYER_LIVE_TEST_PASSWORD
  fi
fi

test_filter=()
case "$mode" in
  replay)
    test_filter=(
      "-only-testing:TVAppPlaybackUITests/PlaybackAutomationUITests/testReplayTuneSwitchSeekAndPlayerLifecycle"
    )
    ;;
  live)
    test_filter=(
      "-only-testing:TVAppPlaybackUITests/PlaybackAutomationUITests/testLiveTVHeadendTuneSwitchAndSeek"
    )
    ;;
esac

xcodegen generate
xcodebuild \
  -project TVApp.xcodeproj \
  -scheme TVApp \
  -configuration Debug \
  -destination "platform=tvOS Simulator,id=$simulator" \
  test \
  "${test_filter[@]}"
