#!/usr/bin/env bash

set -euo pipefail

version="4.0-20260720-1538"
checksum="d9de86d0c755cbcf46c49513ff57fffcd98258f0c7dd29f3e2d23bff3860da2a"
download_dir=".build/VLCKit-download"
install_dir=".build/VLCKit"
archive_name="VLCKit-${version}.zip"
archive_path="${download_dir}/${archive_name}"
framework_path="${install_dir}/VLCKit.xcframework"

if [[ -d "$framework_path" ]]; then
  echo "VLCKit ${version} is already installed."
  exit 0
fi

mkdir -p "$download_dir" "$install_dir"
if [[ ! -f "$archive_path" ]]; then
  curl -fL "https://download.videolan.org/cocoapods/prod/${archive_name}" -o "$archive_path"
fi

actual_sha256="$(shasum -a 256 "$archive_path" | awk '{print $1}')"
if [[ "$actual_sha256" != "$checksum" ]]; then
  echo "VLCKit checksum mismatch (expected ${checksum}, got ${actual_sha256})." >&2
  exit 1
fi

unzip -q -o "$archive_path" -d "$install_dir"
echo "Installed unified VLCKit ${version} in ${install_dir}."
