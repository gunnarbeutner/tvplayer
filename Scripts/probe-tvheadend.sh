#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <base-url> <username>" >&2
  exit 2
fi

base_url="${1%/}"
username="$2"

read -r -s -p "TVHeadend password: " password
echo

auth=(--fail --silent --show-error --anyauth --user "${username}:${password}")

server="$(curl "${auth[@]}" "${base_url}/api/serverinfo")"
profiles="$(curl "${auth[@]}" "${base_url}/api/profile/list")"
channels="$(curl "${auth[@]}" "${base_url}/api/channel/grid?start=0&limit=5")"
epg="$(curl "${auth[@]}" "${base_url}/api/epg/events/grid?start=0&limit=5")"

jq -n \
  --argjson server "$server" \
  --argjson profiles "$profiles" \
  --argjson channels "$channels" \
  --argjson epg "$epg" \
  '{
    server: $server,
    profiles: [$profiles.entries[] | {key, val}],
    channel_count: $channels.total,
    channel_sample: [$channels.entries[] | {uuid, number, name, icon_public_url, icon}],
    epg_count: $epg.total,
    epg_sample: [$epg.entries[] | {eventId, channelUuid, channelName, title, subtitle, start, stop}]
  }'
