#!/usr/bin/env bash
# Per-game FSR4 A/B/C research harness. Does not edit system drivers or game files.
set -Eeuo pipefail
ROOT="${BC250_FSR4_RESULTS_ROOT:-$HOME/.local/share/bc250-framework/fsr4-bench}"
EXACT="${BC250_FSR4_CYBOMAN_DIR:-}"
ICD="${BC250_FSR4_V3_ICD:-$HOME/.local/share/bc250-fsr4/v3/radv-bc250-fsr4-v3.json}"
die(){ echo "bc fsr4: $*" >&2; exit 2; }
usage(){
cat <<'EOF'
A/B/C single-player DX12 test, no anti-cheat:
  bc fsr4 status
  bc fsr4 launch default -- %command%
  BC250_FSR4_CYBOMAN_DIR=/absolute/own/override bc fsr4 launch cyboman -- %command%
  BC250_FSR4_V3_ICD=/absolute/v3-icd.json bc fsr4 launch v3 -- %command%
  bc fsr4 report [results-directory]

Run exactly the same benchmark scene in each mode, 3 repeats/mode.
Toggle MangoHud logging at benchmark start/end (normally Shift_L+F2).
EOF
}
check_exact(){
  [[ -n "$EXACT" && "$EXACT" = /* && -d "$EXACT" ]] || die "Set BC250_FSR4_CYBOMAN_DIR to exact shaders generated from your own Proton dump"
  compgen -G "$EXACT/*.spv" >/dev/null || die "No shader .spv files in $EXACT"
  [[ "$EXACT" != *lossy* ]] || die "Lossy shaders are not allowed in the exact test"
}
check_v3(){
  command -v lspci >/dev/null && lspci -Dn | grep -qi '1002:13fe' || die "BC250 PCI 1002:13FE not detected"
  [[ "$ICD" = /* && -f "$ICD" ]] || die "V3 ICD JSON missing: $ICD"
  local lib
  lib="$(python3 - "$ICD" <<'PY'
import json,sys
print(json.load(open(sys.argv[1],encoding="utf-8")).get("ICD",{}).get("library_path",""))
PY
)"
  [[ "$lib" = /* && -f "$lib" ]] || die "V3 ICD must point to an existing absolute library"
  if command -v ldd >/dev/null; then
    ! ldd "$lib" | grep -q 'not found' || die "V3 driver missing shared libraries; source rebuild for Bazzite"
  fi
  command -v vulkaninfo >/dev/null || die "vulkaninfo required for V3 preflight"
  VK_DRIVER_FILES="$ICD" vulkaninfo --summary >/dev/null 2>&1 || die "V3 driver failed vulkaninfo"
}
launch(){
  local mode="${1:-}"; shift || true
  [[ "${1:-}" == "--" ]] || die "Expected launch MODE -- GAME"
  shift
  (($#)) || die "No game command given"
  [[ "$(id -u)" -ne 0 ]] || die "Run as desktop user, not root"
  case "$mode" in default|cyboman|v3) ;; *) die "Mode must be default, cyboman or v3";; esac
  # The existing BC250 async driver may already be selected by Vulkan ICD env.
  # Preserve that BASELINE for both default and cyboman; only V3 replaces it.
  local base_icd="${BC250_FSR4_BASE_ICD:-${VK_DRIVER_FILES:-}}"
  local base_legacy_icd="${VK_ICD_FILENAMES:-}"
  unset VKD3D_SHADER_OVERRIDE VK_DRIVER_FILES VK_ICD_FILENAMES VK_ADD_DRIVER_FILES
  if [[ "$mode" != v3 ]]; then
    [[ -z "$base_icd" ]] || export VK_DRIVER_FILES="$base_icd"
    [[ -n "$base_icd" || -z "$base_legacy_icd" ]] || export VK_ICD_FILENAMES="$base_legacy_icd"
  fi
  case "$mode" in
    cyboman) check_exact; export VKD3D_SHADER_OVERRIDE="Z:$EXACT" ;;
    v3) check_v3; export VK_DRIVER_FILES="$ICD" ;;
  esac
  local stamp dir
  stamp="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  dir="$ROOT/$mode/$stamp"
  mkdir -p "$dir/logs"
  {
    echo "mode=$mode"
    echo "utc=$stamp"
    echo "kernel=$(uname -r)"
    echo "proton=${STEAM_COMPAT_TOOL_PATHS:-unknown}"
    echo "shader_override=${VKD3D_SHADER_OVERRIDE:-none}"
    echo "vulkan_icd=${VK_DRIVER_FILES:-system}"
    command -v lspci >/dev/null && lspci -Dn | grep -i '1002:13fe' || true
    command -v rpm-ostree >/dev/null && rpm-ostree status -b 2>/dev/null || true
  } > "$dir/context.txt"
  export MANGOHUD=1
  export MANGOHUD_CONFIG="${MANGOHUD_CONFIG:+$MANGOHUD_CONFIG,}output_folder=$dir/logs,log_interval=0,log_duration=0,benchmark_percentiles=AVG+1+0.1"
  echo "BC250 FSR4 $mode, capture path: $dir/logs" >&2
  echo "Start/stop MangoHud logging manually at the benchmark scene." >&2
  exec "$@"
}
case "${1:-help}" in
  status)
    echo "Mode: 3-way research, no system-wide changes"
    echo "cyboman override: ${EXACT:-not configured}"
    echo "V3 ICD: $ICD"
    echo "Results: $ROOT"
    echo "Verify in-game FSR 4.1.1 provider and confirm exact shader overrides match YOUR Proton dump."
    echo "RC11 may use altered shader hashes; absence of an error does not prove optimization."
    ;;
  launch) shift; launch "$@" ;;
  report)
    shift; basedir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
    exec python3 "$basedir/helpers/fsr4_bench_report.py" "${1:-$ROOT}"
    ;;
  help|-h|--help) usage ;;
  *) usage; exit 2 ;;
esac
