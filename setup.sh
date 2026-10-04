#!/usr/bin/env bash
set -Eeuo pipefail

MODE="${1:-apply}"
case "$MODE" in
  apply|--apply) MODE=apply ;;
  check|--check|status) MODE=check ;;
  *) echo "Usage: bc setup [--check]" >&2; exit 2 ;;
esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$HERE/lib"
STATE_DIR="/var/lib/bc250-framework/setup-v1"
STATE_FILE="$STATE_DIR/status.env"
LOG_DIR="/var/log/bc250"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="$LOG_DIR/bc-setup-$STAMP.log"

TARGET_USER="${SUDO_USER:-${USER:-}}"
if [[ -z "$TARGET_USER" || "$TARGET_USER" == root ]] || ! id "$TARGET_USER" >/dev/null 2>&1; then
  TARGET_USER="$(getent passwd 1000 | cut -d: -f1 || true)"
fi
[[ -n "$TARGET_USER" ]] || { echo "ERROR: desktop user not found." >&2; exit 3; }
HOME_DIR="$(getent passwd "$TARGET_USER" | cut -d: -f6)"

die(){ echo "ERROR: $*" >&2; exit 1; }
ok(){ printf '[ OK ] %s\n' "$*"; }
warn(){ printf '[WARN] %s\n' "$*" >&2; }

is_bc250(){ lspci -Dn 2>/dev/null | grep -qi '1002:13fe'; }
is_bazzite(){ grep -qiE '(^ID="?bazzite"?$|bazzite)' /etc/os-release 2>/dev/null; }

find_fsr4_tool(){
  local d
  for d in     "$HOME_DIR/.local/share/Steam/compatibilitytools.d/protonge-latest-bc250"     "$HOME_DIR/.steam/root/compatibilitytools.d/protonge-latest-bc250"     "$HOME_DIR/.steam/steam/compatibilitytools.d/protonge-latest-bc250"; do
    [[ -x "$d/proton" && -x "$d/files/bin/wine" ]] && { printf '%s\n' "$d"; return 0; }
  done
  return 1
}

gpu_busy_path(){
  local p value
  for p in /sys/class/drm/renderD*/device/gpu_busy_percent /sys/class/drm/card*/device/gpu_busy_percent; do
    [[ -r "$p" ]] || continue
    value="$(cat "$p" 2>/dev/null || true)"
    [[ "$value" =~ ^[0-9]+$ ]] && { printf '%s\n' "$p"; return 0; }
  done
  return 1
}

preflight(){
  echo "=== BC250 setup preflight ==="
  is_bc250 || die "AMD BC-250 PCI ID 1002:13fe not detected."
  is_bazzite || die "BC250 setup currently supports the Bazzite production image only."
  [[ -x /usr/bin/bc250-reference-profile ]] || die "bc250-reference-profile is missing from the image."
  command -v bc250-control-center-cli >/dev/null 2>&1 || die "BC250 Control Center CLI is missing."
  [[ -x "$LIB_DIR/control-center.sh" ]] || die "framework Control Center integration is missing."
  [[ -x "$LIB_DIR/sync-components.sh" ]] || die "framework component sync is missing."
  [[ -x "$LIB_DIR/fsr4-lutris.sh" ]] || die "framework FSR4 Lutris policy is missing."
  [[ -x /usr/share/bc250-deploy/modules/36-fsr4-proton.sh ]] || die "FSR4 Proton installer is missing."
  gpu_busy_path >/dev/null || die "kernel gpu_busy_percent is unavailable; refusing the known-bad Cyan busy-flag path."

  local cores threads
  cores="$(lscpu -p=CORE 2>/dev/null | grep -v '^#' | sort -u | wc -l || true)"
  threads="$(nproc --all 2>/dev/null || echo 0)"
  echo "CPU topology: ${cores}C/${threads}T"
  if [[ "$cores" == 8 ]]; then
    [[ "$(modinfo -F bc250_8core_metrics amdgpu 2>/dev/null || true)" == 1 ]] ||
      die "8 cores are visible but the running amdgpu lacks BC250 8-core metrics support."
    ok "8-core telemetry decoder active"
  elif [[ "$cores" == 6 ]]; then
    warn "CPU is still 6-core. Setup can continue, but 8C firmware qualification is not complete."
  else
    die "unsupported BC250 CPU topology: ${cores}C/${threads}T"
  fi
}

verify(){
  local failed=0
  echo
  echo "=== BC250 setup verification ==="

  for svc in bc250-smu-oc.service cyan-skillfish-governor-smu.service coolercontrold.service apu-telemetry.service; do
    if systemctl is-enabled --quiet "$svc" && systemctl is-active --quiet "$svc"; then
      ok "$svc active"
    else
      echo "[FAIL] $svc is not enabled+active" >&2
      failed=1
    fi
  done

  if grep -Eq '^frequency[[:space:]]*=[[:space:]]*3700([[:space:]]|$)' /etc/bc250-smu-oc.conf 2>/dev/null &&
     grep -Eq '^scale[[:space:]]*=[[:space:]]*-24([[:space:]]|$)' /etc/bc250-smu-oc.conf 2>/dev/null &&
     grep -Eq '^temperature[[:space:]]*=[[:space:]]*85([[:space:]]|$)' /etc/bc250-smu-oc.conf 2>/dev/null; then
    ok "CPU profile 3700 / -24 / 85C"
  else
    echo "[FAIL] CPU reference profile mismatch" >&2
    failed=1
  fi

  if grep -Eq '^[[:space:]]*method[[:space:]]*=[[:space:]]*"kernel"([[:space:]]|$)' /etc/cyan-skillfish-governor-smu/config.toml 2>/dev/null &&
     grep -Eq '^[[:space:]]*min[[:space:]]*=[[:space:]]*500([[:space:]]|$)' /etc/cyan-skillfish-governor-smu/config.toml 2>/dev/null &&
     grep -Eq '^[[:space:]]*max[[:space:]]*=[[:space:]]*1970([[:space:]]|$)' /etc/cyan-skillfish-governor-smu/config.toml 2>/dev/null &&
     grep -Eq '^[[:space:]]*frequency[[:space:]]*=[[:space:]]*1970([[:space:]]|$)' /etc/cyan-skillfish-governor-smu/config.toml 2>/dev/null &&
     grep -Eq '^[[:space:]]*voltage[[:space:]]*=[[:space:]]*975([[:space:]]|$)' /etc/cyan-skillfish-governor-smu/config.toml 2>/dev/null; then
    ok "GPU profile 500..1970 / 1970@975 / kernel utilization"
  else
    echo "[FAIL] GPU reference profile mismatch" >&2
    failed=1
  fi

  if busctl --system status com.cyanskillfish.Governor >/dev/null 2>&1; then
    ok "Cyan D-Bus ready"
  else
    echo "[FAIL] Cyan D-Bus unavailable" >&2
    failed=1
  fi

  if command -v bc250-async-compute >/dev/null 2>&1; then
    if bc250-async-compute always status 2>/dev/null | grep -qiE 'enabled|on|always'; then
      ok "GFX1013 async RADV always-on"
    else
      warn "async helper exists, but always-on state could not be confirmed from its text output"
    fi
  else
    echo "[FAIL] bc250-async-compute is missing" >&2
    failed=1
  fi

  if [[ -f "$HOME_DIR/.local/share/bc250-control-center/frontends/desktop/main.py" ]] &&
     [[ -x "$HOME_DIR/.local/bin/bc250-control-center" ]]; then
    cc_version="$(cat "$HOME_DIR/.local/share/bc250-control-center/VERSION" 2>/dev/null || echo unknown)"
    ok "Upstream Control Center user-local runtime: $cc_version"
  else
    echo "[FAIL] independent upstream Control Center runtime is missing" >&2
    failed=1
  fi

  if grep -Fq 'max=1970' "$HOME_DIR/.config/bc250-control-center/ui.conf" 2>/dev/null &&
     grep -Fq 'frequency=3700' "$HOME_DIR/.config/bc250-control-center/ui.conf" 2>/dev/null; then
    ok "BC Framework Control Center profiles present"
  else
    echo "[FAIL] BC Framework Control Center profile data is missing" >&2
    failed=1
  fi

  if find_fsr4_tool >/dev/null; then
    ok "BC250 FSR4 Proton installed"
  else
    echo "[FAIL] protonge-latest-bc250 is missing" >&2
    failed=1
  fi

  cu_result="/var/lib/bc250-framework/cu-test/result.env"
  if [[ -r "$cu_result" ]] && systemctl is-enabled --quiet bc250-cu-live-manager.service 2>/dev/null; then
    cu_value="$(sed -n 's/^cu=//p' "$cu_result" | tail -n1)"
    case "$cu_value" in
      36|40) ok "CU/WGP FurMark qualification persisted: ${cu_value}CU" ;;
      *) echo "[FAIL] invalid CU qualification result: ${cu_value:-missing}" >&2; failed=1 ;;
    esac
  else
    echo "[FAIL] CU/WGP qualification is not complete" >&2
    failed=1
  fi

  local pass_state="PASS"
  (( failed == 0 )) || pass_state="FAIL"
  sudo install -d -m 0755 "$STATE_DIR"
  {
    echo "status=$pass_state"
    echo "checked=$(date -Is)"
    echo "user=$TARGET_USER"
    echo "cu=$(sed -n 's/^cu=//p' /var/lib/bc250-framework/cu-test/result.env 2>/dev/null | tail -n1 || true)"
  } | sudo tee "$STATE_FILE" >/dev/null
  sudo chmod 0644 "$STATE_FILE"

  if (( failed )); then
    echo
    echo "=== BC250 SETUP: FAIL ===" >&2
    return 1
  fi

  echo
  echo "=== BC250 AUTOMATED SETUP: PASS ==="
  echo "Hardware and software provisioning are complete."
  echo "CU/WGP qualification was completed interactively with FurMark."
}

if [[ "$MODE" == check ]]; then
  sudo -v
  preflight
  verify
  exit $?
fi

sudo -v
sudo install -d -m 0755 "$LOG_DIR" "$STATE_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "========================================"
echo "          BC250 AUTOMATED SETUP         "
echo "========================================"
echo "User: $TARGET_USER"
echo "Log:  $LOG_FILE"
echo

preflight

echo
echo "[1/8] Applying the safe BC250 production hardware profile..."
sudo /usr/bin/bc250-reference-profile enable

echo
echo "[2/8] Qualifying CU/WGP layout (interactive FurMark visual checks)..."
bash "$HERE/cu-test.sh"

echo
echo "[3/8] Installing clean upstream Control Center user runtime + BC Framework settings..."
BC250_TARGET_USER="$TARGET_USER" bash "$LIB_DIR/control-center.sh" configure

echo
echo "[4/8] Installing/verifying BC250 FSR4 Proton..."
sudo env BC250_TARGET_USER="$TARGET_USER" bash /usr/share/bc250-deploy/modules/36-fsr4-proton.sh

echo
echo "[5/8] Synchronizing upstream Control Center inventory + OptiScaler, then repairing async RADV..."
bash "$LIB_DIR/sync-components.sh"

echo
echo "[6/8] Applying selective FSR4 policy to Linux-confirmed compatible Lutris games..."
bash "$LIB_DIR/fsr4-lutris.sh"

echo
echo "[7/8] Refreshing BC250 Steam shortcuts..."
if command -v bc250-steam-shortcuts >/dev/null 2>&1; then
  sudo -u "$TARGET_USER" env HOME="$HOME_DIR" USER="$TARGET_USER" LOGNAME="$TARGET_USER"     bc250-steam-shortcuts --force || warn "Steam shortcut refresh deferred until Steam is running."
else
  warn "bc250-steam-shortcuts is not installed; skipping."
fi

echo
echo "[8/8] Placing the administrator password helper on the desktop..."
password_desktop="/usr/share/applications/bc250-set-admin-password.desktop"
if [[ -r "$password_desktop" ]]; then
  desktop_dir="$(sudo -u "$TARGET_USER" env HOME="$HOME_DIR" xdg-user-dir DESKTOP 2>/dev/null || true)"
  [[ -n "$desktop_dir" ]] || desktop_dir="$HOME_DIR/Desktop"
  sudo install -d -o "$TARGET_USER" -g "$(id -gn "$TARGET_USER")" -m 0755 "$desktop_dir"
  sudo install -o "$TARGET_USER" -g "$(id -gn "$TARGET_USER")" -m 0755 \
    "$password_desktop" "$desktop_dir/BC250-Administrator-Password.desktop"
  ok "Administrator password helper: $desktop_dir/BC250-Administrator-Password.desktop"
else
  warn "Administrator password desktop entry is missing from the image."
fi

verify
