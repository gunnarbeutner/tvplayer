#!/usr/bin/env bash

set -euo pipefail

version="3.7.3"
build="319ed2c0-79128878"
download_dir=".build/VLCKit-download"
install_dir=".build/VLCKit"

install_framework() {
  local flavor="$1"
  local checksum="$2"
  local destination="$3"
  local archive_name="${flavor}-${version}-${build}.tar.xz"
  local archive_path="${download_dir}/${flavor}.tar.xz"
  local framework_path="${install_dir}/${destination}/${flavor}.xcframework"

  if [[ -d "$framework_path" ]]; then
    echo "${flavor} ${version} is already installed."
    return
  fi

  mkdir -p "$download_dir" "${install_dir}/${destination}"
  if [[ ! -f "$archive_path" ]]; then
    curl -fL "https://download.videolan.org/cocoapods/prod/${archive_name}" -o "$archive_path"
  fi

  local actual_sha256
  actual_sha256="$(shasum -a 256 "$archive_path" | awk '{print $1}')"
  if [[ "$actual_sha256" != "$checksum" ]]; then
    echo "${flavor} checksum mismatch (expected ${checksum}, got ${actual_sha256})." >&2
    exit 1
  fi

  tar -xJf "$archive_path" -C "${install_dir}/${destination}" --strip-components=1
  echo "Installed ${flavor} ${version} in ${install_dir}/${destination}."
}

# Keep the existing tvOS location stable for current build scripts.
if [[ ! -d "${install_dir}/TVVLCKit.xcframework" ]]; then
  install_framework "TVVLCKit" "b5f90c226ed54d9dc1c03901c60dc7749b74a53caace2c3047e4c0b7a063e46c" "."
fi
install_framework "MobileVLCKit" "0d04059906962ddc9a7bd1ebaa12e1f9ae85eb2466116a97a2f46886dd27a0a9" "Mobile"
install_framework "VLCKit" "019afdae4e2e2d0f3ac325fac8f7ba0af25dca70b9d157df7d60db88e0be8e5d" "macOS"
