#!/usr/bin/env bash

set -euo pipefail

version="3.7.3"
archive_name="TVVLCKit-${version}-319ed2c0-79128878.tar.xz"
expected_sha256="b5f90c226ed54d9dc1c03901c60dc7749b74a53caace2c3047e4c0b7a063e46c"
download_dir=".build/VLCKit-download"
install_dir=".build/VLCKit"
archive_path="${download_dir}/TVVLCKit.tar.xz"
framework_path="${install_dir}/TVVLCKit.xcframework"

if [[ -d "$framework_path" ]]; then
  echo "TVVLCKit ${version} is already installed."
  exit 0
fi

mkdir -p "$download_dir" "$install_dir"
curl -fL "https://download.videolan.org/cocoapods/prod/${archive_name}" -o "$archive_path"

actual_sha256="$(shasum -a 256 "$archive_path" | awk '{print $1}')"
if [[ "$actual_sha256" != "$expected_sha256" ]]; then
  echo "TVVLCKit checksum mismatch (expected ${expected_sha256}, got ${actual_sha256})." >&2
  exit 1
fi

tar -xJf "$archive_path" -C "$install_dir" --strip-components=1
echo "Installed TVVLCKit ${version} in ${install_dir}."
