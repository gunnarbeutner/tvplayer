def pad($width):
  tostring
  | if length >= $width then .
    else ("0" * ($width - length)) + .
    end;

def program_id($channel_index; $program_index; $first_future_index; $anchor):
  if .start <= $anchor and $anchor < .end then
    "guide-test-current-\(($channel_index + 1) | pad(2))"
  elif $program_index == $first_future_index then
    "guide-test-future-\(($channel_index + 1) | pad(2))"
  else
    "guide-test-program-\(($channel_index + 1) | pad(2))-\(($program_index + 1) | pad(4))"
  end;

.snapshots
| to_entries
| map(.value)
| max_by([.channels[].programs[]] | length)
| . as $snapshot
| $snapshot.savedAt as $anchor
| {
    version: 1,
    anchorDate: $anchor,
    channels: [
      $snapshot.channels
      | to_entries[]
      | .key as $channel_index
      | .value as $channel
      | ($channel.programs | map(.start > $anchor) | index(true)) as $first_future_index
      | {
          id: "guide-test-channel-\(($channel_index + 1) | pad(2))",
          number: ($channel_index + 1),
          name: "Guide Test Channel \($channel_index + 1)",
          monogram: "G\($channel_index + 1)",
          programs: [
            $channel.programs
            | to_entries[]
            | .key as $program_index
            | .value
            | {
                id: program_id(
                  $channel_index;
                  $program_index;
                  $first_future_index;
                  $anchor
                ),
                title: "Test Programme \($channel_index + 1)-\($program_index + 1)",
                subtitle: "Anonymized guide fixture",
                overview: "Deterministic programme for guide focus automation.",
                startOffset: (.start - $anchor),
                endOffset: (.end - $anchor)
              }
          ]
        }
    ]
  }
