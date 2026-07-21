#!/usr/bin/env bash

set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "usage: $0 <server-url> <username> [simulator-udid]" >&2
  exit 2
fi

server_url="${1%/}"
username="$2"
simulator="${3:-booted}"
app_path="${TVPLAYER_APP_PATH:-.build/DerivedData/Build/Products/Debug-appletvsimulator/TVApp.app}"

if [[ ! -d "$app_path" ]]; then
  echo "Build the TVApp scheme before running this script." >&2
  exit 1
fi

if ! codesign --verify --strict "$app_path"; then
  echo "Refusing to install an unsigned or invalidly signed app: $app_path" >&2
  exit 1
fi

executable_name="$(plutil -extract CFBundleExecutable raw "$app_path/Info.plist")"
executable_path="$app_path/$executable_name"
entitlement_strings_path="$(mktemp "${TMPDIR:-/tmp}/tvplayer-entitlements.XXXXXX")"
trap 'rm -f "$entitlement_strings_path"' EXIT
strings "$executable_path" >"$entitlement_strings_path"
if ! grep -q 'keychain-access-groups' "$entitlement_strings_path" ||
   ! grep -q 'runs-as-current-user-with-user-independent-keychain' "$entitlement_strings_path"; then
  echo "Refusing to install an app without the simulated Keychain entitlements: $app_path" >&2
  exit 1
fi

read -r -s -p "TVHeadend password: " password
echo

xcrun simctl install "$simulator" "$app_path"

SIMCTL_CHILD_TVPLAYER_TVH_URL="$server_url" \
SIMCTL_CHILD_TVPLAYER_TVH_USERNAME="$username" \
SIMCTL_CHILD_TVPLAYER_TVH_PASSWORD="$password" \
SIMCTL_CHILD_TVPLAYER_TVH_PROFILE="pass" \
SIMCTL_CHILD_TVPLAYER_TVH_HTSP_PORT="${TVPLAYER_TVH_HTSP_PORT:-9982}" \
SIMCTL_CHILD_TVPLAYER_AUTOPLAY="${TVPLAYER_AUTOPLAY:-0}" \
SIMCTL_CHILD_TVPLAYER_PAUSE_TEST="${TVPLAYER_PAUSE_TEST:-0}" \
xcrun simctl launch --terminate-running-process "$simulator" de.beutner.TVPlayer
