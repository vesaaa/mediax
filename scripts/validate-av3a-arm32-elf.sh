#!/usr/bin/env bash
# 校验 arm-av3a 工件中 armeabi-v7a 的 AV3A 伴生库是否可被 Android 32 位 linker 加载。
# 预编译库若含 DT_RELASZ 或缺少 GNU_HASH，会在真机 dlopen 失败（有画无声）。
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <path-to-aar-or-apk> [path-to-aar-or-apk...]" >&2
  exit 2
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

check_arm32_av3a_libs() {
  local archive="$1"
  local name
  name="$(basename "$archive")"
  if [[ ! -f "$archive" ]]; then
    echo "ERROR: missing archive: $archive" >&2
    return 1
  fi

  local found=0
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    found=1
    local so_path="${TMP}/${name}/${entry}"
    mkdir -p "$(dirname "$so_path")"
    unzip -p "$archive" "$entry" > "$so_path"

    if readelf -d "$so_path" 2>/dev/null | grep -q '(RELA)'; then
      echo "ERROR: ${name}:${entry} has RELA relocations (unsupported on armeabi-v7a Android linker)" >&2
      return 1
    fi
    if ! readelf -d "$so_path" 2>/dev/null | grep -qE 'GNU_HASH|\(HASH\)'; then
      echo "ERROR: ${name}:${entry} missing DT_GNU_HASH/DT_HASH" >&2
      return 1
    fi
    echo "OK: ${name}:${entry}"
  done < <(unzip -Z1 "$archive" | grep -E '^lib/armeabi-v7a/(libAVS3AudioDec|libav3a_binaural_render)\.so$' || true)

  if [[ "$found" -eq 0 ]]; then
    echo "OK: ${name} has no armeabi-v7a AV3A companion libs (expected for av3a7+ builds)"
  fi
  return 0
}

for archive in "$@"; do
  check_arm32_av3a_libs "$archive"
done
