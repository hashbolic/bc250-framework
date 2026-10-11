#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
LUTRIS="$ROOT/helpers/fsr4_lutris.py"
REPORT="$ROOT/helpers/fsr4_bench_report.py"
LAB="$HOME/.local/share/bc250-framework/fsr4-research"
CYBO="$HOME/.cache/bc250-framework/fsr4-cyboman-source"
V3SRC="$HOME/.cache/bc250-framework/fsr4-v3-source"
V3="$HOME/.local/share/bc250-fsr4/v3/radv-bc250-fsr4-v3.json"
DUMP="$LAB/shader-dump"
EXACT="$LAB/exact-overrides"
die(){ echo "bc fsr4: $*" >&2; exit 1; }
preflight(){
  [[ "$(id -u)" -ne 0 ]] || die "run without sudo"
  command -v lspci >/dev/null && lspci -Dn | grep -qi '1002:13fe' || die "BC250 GPU missing"
  python3 "$LUTRIS" status
}
checkout(){
  local url="$1" dest="$2" branch="$3"
  command -v git >/dev/null || die "git missing"
  if [[ ! -d "$dest/.git" ]]; then
    mkdir -p "$(dirname "$dest")"
    git clone --depth 1 --branch "$branch" "$url" "$dest"
  else
    [[ "$(git -C "$dest" remote get-url origin)" == "$url" ]] || die "unknown upstream at $dest"
  fi
  echo "Source: $url @ $(git -C "$dest" rev-parse --short=12 HEAD)"
}
clone_cyboman(){
  checkout "https://github.com/zgauthier2000/fsr4-shader-performance-overrides.git" "$CYBO" main
}
build_exact(){
  clone_cyboman
  compgen -G "$DUMP/*.spv" >/dev/null || return 1
  mkdir -p "$EXACT"
  if command -v spirv-dis >/dev/null && command -v spirv-as >/dev/null && command -v spirv-val >/dev/null; then
    bash "$CYBO/tools/build_override.sh" "$DUMP" "$EXACT" ||
      die "cyboman did not recognize FSR4 shaders from this Proton/RC11"
  elif command -v podman >/dev/null; then
    local fedora
    fedora="$(. /etc/os-release; echo "${VERSION_ID%%.*}")"
    [[ "$fedora" =~ ^[0-9]+$ ]] || die "Cannot detect Fedora version"
    podman run --rm --security-opt label=disable \
      -v "$CYBO:/source:ro" -v "$DUMP:/dump:ro" -v "$EXACT:/output" \
      "docker.io/library/fedora:$fedora" bash -lc \
      'dnf -qy install python3 spirv-tools && bash /source/tools/build_override.sh /dump /output' ||
      die "Unable to compile exact shaders; no guessing prebuilt override"
  else
    die "Need SPIRV-Tools or podman to generate exact shaders"
  fi
  compgen -G "$EXACT/*.spv" >/dev/null || die "No exact shader overrides built"
}
check_v3(){
  [[ -f "$V3" ]] || return 1
  local so
  so="$(python3 - "$V3" <<'PY'
import sys,json
try:
 print(json.load(open(sys.argv[1]))["ICD"]["library_path"])
except (OSError,KeyError,ValueError) as e:
 raise SystemExit(str(e))
PY
)" || return 1
  [[ "$so" = /* && -f "$so" ]] || return 1
  ! ldd "$so" | grep -q 'not found' || return 1
  command -v vulkaninfo >/dev/null || return 1
  VK_DRIVER_FILES="$V3" vulkaninfo --summary >/dev/null 2>&1
}
prepare_v3(){
  check_v3 && return 0
  checkout "https://github.com/dmorazasanchez/bc250-fsr4.git" "$V3SRC" v3
  echo "Checking SHA256-verified V3 prebuilt driver against Bazzite..."
  if bash "$V3SRC/install-v3.sh" && check_v3; then return 0; fi
  echo "V3 incompatible with this Bazzite ABI or Vulkan stack; no system drivers modified."
  echo "V3 needs a compatible user-local Mesa build before an FPS test is possible."
  return 1
}
close_lutris(){
  if pgrep -u "$(id -u)" -f '(^|/)(Cyberpunk2077|REDprelauncher)([. ]|$)' >/dev/null 2>&1; then
    die "Exit Cyberpunk before switching FSR4 test modes"
  fi
  if pgrep -u "$(id -u)" -x lutris >/dev/null 2>&1; then
    pkill -TERM -u "$(id -u)" -x lutris || true
    for _ in {1..12}; do
      pgrep -u "$(id -u)" -x lutris >/dev/null 2>&1 || break
      sleep .5
    done
    pgrep -u "$(id -u)" -x lutris >/dev/null 2>&1 && die "Lutris still open, cannot safely edit config"
  fi
}
start_mode(){
  local mode="$1" arg="${2:-}" output id
  close_lutris
  output="$(python3 "$LUTRIS" apply "$mode" "$arg")" || die "Lutris config failed"
  printf '%s\n' "$output"
  id="$(sed -n 's/^LUTRIS_ID=//p' <<<"$output" | tail -n1)"
  if command -v lutris >/dev/null; then
    if [[ "$id" =~ ^[0-9]+$ ]]; then
      nohup lutris "lutris:rungameid/$id" >/dev/null 2>&1 &
    else
      nohup lutris >/dev/null 2>&1 &
      echo "Please press Play on Cyberpunk inside Lutris."
    fi
    disown || true
  else
    echo "Lutris CLI unavailable; the per-game profile is applied. Launch Cyberpunk normally."
  fi
  echo "To record the SAME test scene use MangoHud Left Shift + F2 to start/stop logging."
  echo "Exit the game before selecting the next test mode."
}
run_mode(){
  case "$1" in
    default) start_mode default ;;
    dump)
      clone_cyboman
      mkdir -p "$DUMP"
      start_mode dump
      echo "Exit Cyberpunk and choose cyboman again: shader compilation is automatic."
      ;;
    cyboman)
      if ! compgen -G "$EXACT/*.spv" >/dev/null; then
        if ! build_exact; then
          echo "Capturing FSR4 shaders once; then run bc fsr4 again and choose option 2."
          run_mode dump
          return
        fi
      fi
      start_mode cyboman "$EXACT"
      ;;
    v3)
      if prepare_v3; then start_mode v3 "$V3"; fi
      ;;
    *) die "Invalid benchmark mode" ;;
  esac
}
menu(){
  preflight
  cat <<'EOF'

BC250 FSR4 test — Cyberpunk 2077
1  Default (current FSR4 + async)
2  cyboman Exact (auto dump/build once)
3  V3 RADV (automatic ABI/ICD verification)
4  FPS report
5  Restore original Lutris config
0  Exit

EOF
  read -r -p "Choice: " selection </dev/tty || return
  case "$selection" in
    1) run_mode default ;;
    2) run_mode cyboman ;;
    3) run_mode v3 ;;
    4) python3 "$REPORT" "$LAB/measurements" ;;
    5) close_lutris; python3 "$LUTRIS" restore ;;
    0) return ;;
    *) die "Unknown selection" ;;
  esac
}
case "${1:-menu}" in
  menu) menu ;;
  default|cyboman|v3|dump) preflight; run_mode "$1" ;;
  report) python3 "$REPORT" "$LAB/measurements" ;;
  status) preflight ;;
  restore) close_lutris; python3 "$LUTRIS" restore ;;
  *) echo "Usage: bc fsr4 [default|cyboman|v3|report|restore]"; exit 2 ;;
esac
