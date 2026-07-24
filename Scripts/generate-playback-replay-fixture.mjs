#!/usr/bin/env node

import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";

const repository = resolve(new URL("..", import.meta.url).pathname);
const destination = resolve(
  process.argv[2] ?? join(repository, "TVApp/Resources/playback-replay.jsonl"),
);
const temporaryDirectory = mkdtempSync(join(tmpdir(), "tvplayer-replay-"));
const transportStream = join(temporaryDirectory, "playback-replay.ts");

function run(executable, commandArguments) {
  const result = spawnSync(executable, commandArguments, {
    encoding: "utf8",
    maxBuffer: 128 * 1024 * 1024,
  });
  if (result.status !== 0) {
    process.stderr.write(result.stderr);
    process.exit(result.status ?? 1);
  }
  return result.stdout;
}

function packetData(hexDump) {
  const hex = (hexDump ?? "")
    .split("\n")
    .map((line) => line.replace(/^[^:]+:\s*/, "").split(/\s{2,}/)[0])
    .join("")
    .replace(/\s/g, "");
  return Buffer.from(hex, "hex");
}

try {
  run("ffmpeg", [
    "-hide_banner",
    "-loglevel",
    "error",
    "-f",
    "lavfi",
    "-i",
    "testsrc2=size=640x360:rate=25",
    "-f",
    "lavfi",
    "-i",
    "sine=frequency=440:sample_rate=48000",
    "-vf",
    [
      "drawbox=x=0:y=0:w=1:h=1:color=white:t=fill",
      "drawbox=x=iw-1:y=0:w=1:h=1:color=white:t=fill",
      "drawbox=x=0:y=ih-1:w=1:h=1:color=white:t=fill",
      "drawbox=x=iw-1:y=ih-1:w=1:h=1:color=white:t=fill",
    ].join(","),
    "-t",
    "16",
    "-c:v",
    "libx264",
    "-preset",
    "veryfast",
    "-pix_fmt",
    "yuv420p",
    "-g",
    "25",
    "-keyint_min",
    "25",
    "-sc_threshold",
    "0",
    "-b:v",
    "600k",
    "-c:a",
    "aac",
    "-b:a",
    "96k",
    "-f",
    "mpegts",
    transportStream,
  ]);

  const probe = JSON.parse(run("ffprobe", [
    "-v",
    "error",
    "-show_packets",
    "-show_data",
    "-show_entries",
    "packet=stream_index,pts_time,dts_time,duration_time,flags,data",
    "-of",
    "json",
    transportStream,
  ]));

  const firstTimestamp = Math.min(
    ...probe.packets.flatMap((packet) => {
      const value = packet.dts_time ?? packet.pts_time;
      return value === undefined ? [] : [Number(value)];
    }),
  );
  const records = probe.packets.flatMap((packet) => {
    if (packet.stream_index !== 0 && packet.stream_index !== 1) return [];
    const payload = packetData(packet.data);
    if (payload.length === 0) return [];
    const micros = (value) => value === undefined
      ? null
      : Math.round((Number(value) - firstTimestamp) * 1_000_000);
    return [{
      streamIndex: packet.stream_index === 0 ? 1 : 2,
      frameType: packet.stream_index === 0 && packet.flags?.includes("K") ? 73 : 0,
      presentationTime: micros(packet.pts_time),
      decodeTime: micros(packet.dts_time),
      durationMicroseconds: packet.duration_time === undefined
        ? null
        : Math.round(Number(packet.duration_time) * 1_000_000),
      payload: payload.toString("base64"),
    }];
  });

  writeFileSync(
    destination,
    records.map((record) => JSON.stringify(record)).join("\n") + "\n",
  );
  const bytes = readFileSync(destination).length;
  process.stdout.write(`Wrote ${records.length} packets (${bytes} bytes) to ${destination}\n`);
} finally {
  rmSync(temporaryDirectory, { recursive: true, force: true });
}
