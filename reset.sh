#!/usr/bin/env bash
set -Eeuo pipefail

MODE="framework"
case "${1:-}" in
  "") ;;
  --clean) MODE="clean" ;;
  -h|--help)
    cat <<'EOF'
Usage:
  bc reset          undo BC250 Framework provisioning on the current immutable OS image
  bc reset --clean  additionally use Bazzite rpm-ostree reset and Steam reset helper

Neither mode deletes installed games or personal files intentionally.
EOF
    exit 0
    ;;
  *) echo "bc reset: unknown option: $1" >&2; exit 2 ;;
esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_ROOT="/var/lib/bc250-framework"
TARGET_USER="${SUDO_USER:-${USER:-}}"
if [[ -z "$TARGET_USER" || "$TARGET_USER" == root ]] || ! id "$TARGET_USER" >/dev/null 2>&1; then
  TARGET_USER="$(getent passwd 1000 | cut -d: -f1 || true)"
fi
[[ -n "$TARGET_USER" ]] || { echo "bc reset: desktop user not found" >&2; exit 3; }
HOME_DIR="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
USER_UID="$(id -u "$TARGET_USER")"
USER_GID="$(id -g "$TARGET_USER")"

warn(){ printf '[WARN] %s\n' "$*" >&2; }
ok(){ printf '[ OK ] %s\n' "$*"; }

run_user(){
  if [[ "$(id -u)" -eq "$USER_UID" ]]; then
    HOME="$HOME_DIR" USER="$TARGET_USER" LOGNAME="$TARGET_USER" "$@"
  else
    sudo -u "$TARGET_USER" env HOME="$HOME_DIR" USER="$TARGET_USER" LOGNAME="$TARGET_USER" "$@"
  fi
}

confirm(){
  local answer
  echo "This returns BC250-specific mutable state to the post-install, pre-'bc setup' state."
  if [[ "$MODE" == clean ]]; then
    echo "Clean mode also invokes stock Bazzite rpm-ostree/Steam reset helpers."
    echo "WARNING: rpm-ostree reset removes ALL layered RPM packages, including ones you added manually."
  fi
  echo "Installed games and personal files are not intentionally removed."
  read -r -p "Continue? [y/N]: " answer </dev/tty
  case "$answer" in y|Y|yes|YES|Yes) ;; *) echo "Cancelled."; exit 0 ;; esac
}

steam_running(){
  pgrep -u "$USER_UID" -x steam >/dev/null 2>&1 ||
  pgrep -u "$USER_UID" -f '/steamwebhelper|/steam -' >/dev/null 2>&1
}

shutdown_steam(){
  steam_running || return 0
  echo "Closing Steam before restoring framework-managed Steam configuration..."
  if command -v steam >/dev/null 2>&1; then
    run_user steam -shutdown >/dev/null 2>&1 || true
  fi
  for _ in {1..30}; do
    steam_running || return 0
    sleep 1
  done
  warn "Steam is still running; Steam/CS2 config restoration will be skipped."
  return 1
}

restore_lutris_backups(){
  local root="$HOME_DIR/.local/share/bc250-framework/lutris-backups"
  [[ -d "$root" ]] || return 0
  local first
  first="$(find "$root" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort | head -n1 || true)"
  [[ -n "$first" ]] || return 0
  echo "Restoring earliest pre-framework Lutris backup: $first"
  run_user cp -a "$root/$first/." "$HOME_DIR/"
  run_user rm -rf "$root"
  ok "Lutris configs restored"
}

cc_root(){
  local p
  for p in "$HOME_DIR/.local/share/bc250-control-center" /usr/local/share/bc250-control-center /usr/share/bc250-control-center; do
    [[ -f "$p/src/bc250cc/infrastructure/sistema_repository.py" ]] && { printf '%s\n' "$p"; return 0; }
  done
  return 1
}

cc_uninstall(){
  local what="$1" root tmp script
  root="$(cc_root || true)"
  [[ -n "$root" ]] || { warn "Control Center source tree unavailable; cannot request $what uninstall."; return 0; }
  tmp="$(run_user mktemp)"
  case "$what" in
    opticlient) method=gestionar_fsr4_bc250 ;;
    gfx1013) method=gestionar_gfx1013_bazzite ;;
    *) return 1 ;;
  esac
  if ! run_user env PYTHONPATH="$root/src" python3 - "$tmp" "$method" <<'PY'
from pathlib import Path
import sys
from bc250cc.infrastructure.sistema_repository import SistemaRepository
path, method = sys.argv[1], sys.argv[2]
repo = SistemaRepository()
repo._abrir_terminal = lambda command, title="": (title, command)
try:
    result = getattr(repo, method)("uninstall")
except Exception as exc:
    print(f"WARN: uninstall request unavailable: {exc}", file=sys.stderr)
    Path(path).write_text("", encoding="utf-8")
    raise SystemExit(0)
if isinstance(result, tuple) and len(result) == 2:
    _title, command = result
    Path(path).write_text(command + "\n", encoding="utf-8")
else:
    Path(path).write_text("", encoding="utf-8")
PY
  then
    rm -f "$tmp"
    warn "Could not generate $what uninstall command."
    return 0
  fi
  if [[ -s "$tmp" ]]; then
    echo "Removing framework-managed $what through BC250 Control Center backend..."
    if ! run_user bash "$tmp"; then
      warn "$what backend uninstall reported an error; continuing with safe state cleanup."
    fi
  fi
  rm -f "$tmp"
}

restore_vendor_file(){
  local etc_path="$1" usr_path="/usr/etc/${1#/etc/}"
  if [[ -f "$usr_path" ]]; then
    sudo install -D -m 0644 "$usr_path" "$etc_path"
  else
    sudo rm -f "$etc_path"
  fi
}

confirm
sudo -v

echo
echo "[1/8] Restoring per-game settings..."
if shutdown_steam; then
  cs2_state="$HOME_DIR/.local/share/bc250-framework/games/cs2.json"
  if [[ -f "$cs2_state" ]]; then
    run_user python3 "$HERE/helpers/steam_launch_options.py" --home "$HOME_DIR" reset ||
      warn "CS2 launch options could not be restored."
  fi
fi
restore_lutris_backups
run_user rm -f "$HOME_DIR/.local/share/lutris/runners/wine/protonge-latest-bc250" 2>/dev/null || true

echo
echo "[2/8] Removing OptiScaler/GFX1013 framework integrations..."
cc_uninstall opticlient
if command -v bc250-async-compute >/dev/null 2>&1; then
  sudo bc250-async-compute always disable >/dev/null 2>&1 || true
fi
cc_uninstall gfx1013

echo
echo "[3/8] Returning CU/WGP dispatch to firmware stock..."
if command -v bc250-cu-live-manager >/dev/null 2>&1; then
  sudo bc250-cu-live-manager --yes uninstall-service >/dev/null 2>&1 || true
  sudo bc250-cu-live-manager --yes stock-dispatch >/dev/null 2>&1 ||
    warn "Could not confirm stock CU dispatch."
fi
sudo rm -f /etc/bc250-cu-live-manager.conf

echo
echo "[4/8] Removing persistent CPU/GPU production tuning..."
sudo systemctl disable --now bc250-smu-oc.service >/dev/null 2>&1 || true
sudo rm -f /etc/bc250-smu-oc.conf
sudo systemctl disable --now cyan-skillfish-governor-smu.service >/dev/null 2>&1 || true
restore_vendor_file /etc/cyan-skillfish-governor-smu/config.toml
sudo rm -f /etc/bc250-console/reference-board-profile.enabled

echo
echo "[5/8] Returning cooling and HUD to clean-image state..."
if [[ -f /etc/bc250-console/coolercontrol-profile.imported ]]; then
  sudo systemctl disable --now coolercontrold.service >/dev/null 2>&1 || true
  sudo rm -rf /etc/coolercontrol
  if [[ -d /usr/etc/coolercontrol ]]; then
    sudo cp -a /usr/etc/coolercontrol /etc/coolercontrol
  fi
  sudo rm -f /etc/bc250-console/coolercontrol-profile.imported
fi
hud="$HOME_DIR/.config/MangoHud/MangoHud.conf"
if [[ -f "$hud" ]] && grep -qE 'BC250|Captured from CachyOS reference board' "$hud"; then
  run_user rm -f "$hud"
fi
run_user rm -rf "$HOME_DIR/.local/share/bc250-mangohud-fps"   "$HOME_DIR/.config/vulkan/implicit_layer.d/MangoHud.x86_64.json" 2>/dev/null || true

echo
echo "[6/8] Removing framework-installed Proton and transient state..."
# Older BC250 images used an automatic first-boot Proton timer. Disable it so
# reset is reliable even when a newer Framework is being tested on an older OS.
sudo systemctl disable --now bc250-firstboot-proton.timer bc250-firstboot-proton.service >/dev/null 2>&1 || true
sudo systemctl disable --now bc250-factory-firstboot.service bc250-factory-reset.service >/dev/null 2>&1 || true
sudo rm -f /var/lib/bc250-console/fsr4-proton-firstboot-v1.ok
for d in   "$HOME_DIR/.local/share/Steam/compatibilitytools.d/protonge-latest-bc250"   "$HOME_DIR/.steam/root/compatibilitytools.d/protonge-latest-bc250"   "$HOME_DIR/.steam/steam/compatibilitytools.d/protonge-latest-bc250"; do
  [[ -e "$d" ]] && run_user rm -rf "$d"
done
sudo rm -f /var/lib/bc250-console/fsr4-proton-current
sudo rm -rf "$STATE_ROOT/setup-v1" "$STATE_ROOT/cu-test"
run_user rm -rf "$HOME_DIR/.cache/bc250-framework" "$HOME_DIR/.local/share/bc250-framework/games" 2>/dev/null || true

echo
echo "[7/8] Returning Control Center to bundled upstream / pre-setup state..."
if [[ -x "$HERE/lib/control-center.sh" ]]; then
  BC250_TARGET_USER="$TARGET_USER" bash "$HERE/lib/control-center.sh" reset
else
  warn "Framework Control Center reset helper is unavailable."
fi

echo
echo "[8/8] Stock Bazzite reset layer..."
needs_reboot=0
if [[ "$MODE" == clean ]]; then
  if command -v rpm-ostree >/dev/null 2>&1; then
    echo "Running stock Bazzite/Fedora Atomic layered-package reset..."
    if sudo rpm-ostree reset; then
      needs_reboot=1
    else
      warn "rpm-ostree reset reported no change or an error."
    fi
  fi
  if command -v ujust >/dev/null 2>&1; then
    echo
    echo "Running Bazzite's stock Steam reset helper..."
    if ! run_user ujust fix-reset-steam; then
      warn "ujust fix-reset-steam did not complete."
    fi
  else
    warn "ujust is unavailable; Steam reset helper skipped."
  fi
else
  echo "Skipped (use 'bc reset --clean' to invoke rpm-ostree reset + Bazzite Steam reset)."
fi

echo
echo "=== BC250 RESET COMPLETE ==="
echo "State: current immutable OS image + clean BC250 pre-setup provisioning."
echo "Next: bc setup"
(( needs_reboot == 0 )) || echo "A reboot is required for the staged rpm-ostree reset deployment."
