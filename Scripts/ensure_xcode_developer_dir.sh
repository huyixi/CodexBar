#!/usr/bin/env bash

ensure_xcode_developer_dir() {
  if [[ -n "${DEVELOPER_DIR:-}" ]]; then
    return 0
  fi

  local selected_developer_dir=""
  selected_developer_dir="$(xcode-select -p 2>/dev/null || true)"
  if [[ "${selected_developer_dir}" != "/Library/Developer/CommandLineTools" ]]; then
    return 0
  fi

  local xcode_developer_dir="/Applications/Xcode.app/Contents/Developer"
  if [[ ! -d "${xcode_developer_dir}" ]]; then
    echo "WARN: xcode-select points to Command Line Tools and ${xcode_developer_dir} was not found." >&2
    return 0
  fi

  export DEVELOPER_DIR="${xcode_developer_dir}"
  echo "==> Using Xcode developer directory: ${DEVELOPER_DIR}"
}
