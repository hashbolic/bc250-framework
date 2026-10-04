#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$HERE/helpers/steam_launch_options.py"
CS2_LAUNCH='taskset -c 1,3,5,9,11,13 mangohud %command%'

die(){ echo "bc game: $*" >&2; exit 1; }

TARGET_USER="${SUDO_USER:-${USER:-}}"
if [[ -z "$TARGET_USER" || "$TARGET_USER" == root ]] || ! id "$TARGET_USER" >/dev/null 2>&1; then
  TARGET_USER="$(getent passwd 1000 | cut -d: -f1 || true)"
fi
[[ -n "$TARGET_USER" ]] || die "desktop user not found"
HOME_DIR="$(getent passwd "$TARGET_USER" | cut -d: -f6)"

run_user(){
  if [[ "$(id -un)" == "$TARGET_USER" ]]; then
    HOME="$HOME_DIR" "$@"
  else
    sudo -u "$TARGET_USER" env HOME="$HOME_DIR" USER="$TARGET_USER" LOGNAME="$TARGET_USER" "$@"
  fi
}

steam_running(){
  pgrep -u "$(id -u "$TARGET_USER")" -x steam >/dev/null 2>&1 ||
  pgrep -u "$(id -u "$TARGET_USER")" -f '/steamwebhelper|/steam -' >/dev/null 2>&1
}

shutdown_steam(){
  steam_running || return 0
  echo "Steam must be closed before localconfig.vdf is changed."
  read -r -p "Close Steam cleanly now? [Y/n]: " answer </dev/tty
  case "$answer" in n|N|no|NO|No) die "cancelled" ;; esac
  if command -v steam >/dev/null 2>&1; then
    run_user steam -shutdown >/dev/null 2>&1 || true
  fi
  for _ in {1..30}; do
    steam_running || return 0
    sleep 1
  done
  die "Steam is still running; refusing to edit its configuration"
}

check_cs2_affinity(){
  command -v taskset >/dev/null 2>&1 || die "taskset is missing"
  command -v mangohud >/dev/null 2>&1 || die "mangohud is missing"
  online=",$(cat /sys/devices/system/cpu/online 2>/dev/null || true),"
  for cpu in 1 3 5 9 11 13; do
    taskset -c "$cpu" true >/dev/null 2>&1 || die "CPU $cpu is not available; CS2 6-thread BC250 affinity profile does not match this topology"
  done
}

usage(){
  cat <<'EOF'
Usage:
  bc game list
  bc game cs2 apply
  bc game cs2 status
  bc game cs2 reset

CS2 profile:
  taskset -c 1,3,5,9,11,13 mangohud %command%

The profile is the BC250-tested 6-thread affinity baseline. It does not change
CS2 graphics settings.
EOF
}

case "${1:-list}" in
  list)
    echo "cs2  Counter-Strike 2  [affinity + MangoHud]"
    ;;
  cs2)
    action="${2:-status}"
    case "$action" in
      status)
        echo "Expected: $CS2_LAUNCH"
        run_user python3 "$HELPER" --home "$HOME_DIR" status || true
        ;;
      apply)
        check_cs2_affinity
        shutdown_steam
        run_user python3 "$HELPER" --home "$HOME_DIR" apply --launch "$CS2_LAUNCH"
        echo "CS2 BC250 profile applied. Start Steam again."
        ;;
      reset)
        shutdown_steam
        run_user python3 "$HELPER" --home "$HOME_DIR" reset
        echo "Original CS2 launch options restored."
        ;;
      *) usage; exit 2 ;;
    esac
    ;;
  help|-h|--help) usage ;;
  *) usage; exit 2 ;;
esac
