#!/usr/bin/env bash
set -Eeuo pipefail

echo "=== BC250 Framework: synchronize BC250 Control Center inventory ==="
echo
echo "This uses the upstream BC250 Control Center backend to prepare the exact reviewed"
echo "sources/artifacts its GUI inventories, then installs its pinned OptiScaler Client."
echo "It does not apply CPU/GPU/CU tuning; bc setup remains the hardware profile owner."
echo

TARGET_USER="${SUDO_USER:-${USER:-}}"
if [[ -z "$TARGET_USER" || "$TARGET_USER" == root ]] || ! id "$TARGET_USER" >/dev/null 2>&1; then
  TARGET_USER="$(getent passwd 1000 | cut -d: -f1 || true)"
fi
[[ -n "$TARGET_USER" ]] || { echo "ERROR: desktop user not found." >&2; exit 2; }
HOME_DIR="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
USER_UID="$(id -u "$TARGET_USER")"

bc250cc_gui_pids() {
  ps -u "$TARGET_USER" -o pid=,args= 2>/dev/null | awk '
    /python3 .*frontends\.desktop\.main/ ||
    /python3 .*frontends\/desktop\/main\.py/ ||
    /(^|[[:space:]\/])bc250-control-center([[:space:]]|$)/ {
      print $1
    }'
}

GUI_WAS_RUNNING=0
if [[ -n "$(bc250cc_gui_pids)" ]]; then
  GUI_WAS_RUNNING=1
fi

CC_ROOT=""
for candidate in "$HOME_DIR/.local/share/bc250-control-center" /usr/local/share/bc250-control-center /usr/share/bc250-control-center; do
  if [[ -f "$candidate/src/bc250cc/infrastructure/sistema_repository.py" ]]; then
    CC_ROOT="$candidate"
    break
  fi
done
[[ -n "$CC_ROOT" ]] || { echo "ERROR: upstream BC250 Control Center source tree not found." >&2; exit 3; }

sudo -v

tmpdir="$(mktemp -d /var/tmp/bc250-cc-sync.XXXXXX)"
trap 'rm -rf "$tmpdir"' EXIT
prep_cmd="$tmpdir/prepare.sh"
gddr6_cmd="$tmpdir/gddr6.sh"
fsr4_cmd="$tmpdir/fsr4.sh"
async_cmd="$tmpdir/async.sh"

echo "[1/6] Asking BC250 Control Center for its own full preparation workflow..."
sudo -u "$TARGET_USER" env \
  HOME="$HOME_DIR" USER="$TARGET_USER" LOGNAME="$TARGET_USER" \
  PYTHONPATH="$CC_ROOT/src" \
  python3 - "$prep_cmd" <<'PY'
from pathlib import Path
import sys
from bc250cc.infrastructure.sistema_repository import SistemaRepository

repo = SistemaRepository()
repo._abrir_terminal = lambda command, title="": (title, command)
title, command = repo.instalar_dependencias_bc250(
    confirmar_conflictos=True,
    desactivar_conflictos=True,
    governor_preference="cyan",
    include_pwm=True,
    components={
        "runtime",
        "governor",
        "cpu_oc",
        "core_unlock",
        "gddr6_temp",
        "umr",
        "cu_manager",
        "fan_pwm",
    },
)
Path(sys.argv[1]).write_text(command + "\n", encoding="utf-8")
print(title or "BC250 Control Center preparation")
PY
chmod 0700 "$prep_cmd"

echo
echo "[2/6] Running BC250 Control Center preparation as $TARGET_USER..."
sudo -u "$TARGET_USER" env \
  HOME="$HOME_DIR" USER="$TARGET_USER" LOGNAME="$TARGET_USER" \
  XDG_CONFIG_HOME="$HOME_DIR/.config" \
  XDG_DATA_HOME="$HOME_DIR/.local/share" \
  XDG_CACHE_HOME="$HOME_DIR/.cache" \
  bash "$prep_cmd"

echo
echo "[3/6] Preparing the reviewed GDDR6 source that Bazzite's immutable workflow does not stage..."
sudo -u "$TARGET_USER" env \
  HOME="$HOME_DIR" USER="$TARGET_USER" LOGNAME="$TARGET_USER" \
  PYTHONPATH="$CC_ROOT/src" \
  python3 - "$gddr6_cmd" <<'PY'
from pathlib import Path
import sys
from bc250cc.infrastructure.sistema_repository import SistemaRepository
from bc250cc.infrastructure.external_tools.catalog import (
    EXTERNAL_TOOL_DIRECTORIES,
    EXTERNAL_TOOLS,
)

repo = SistemaRepository()
os_repo = repo._os_repository()
spec = EXTERNAL_TOOLS["gddr6_memory_temp"]
destination = repo._tool_dir() / EXTERNAL_TOOL_DIRECTORIES["gddr6_memory_temp"]
command = repo._hardware_source_checkout_command(
    spec.upstream,
    destination,
    os_repo,
)
Path(sys.argv[1]).write_text(command + "\n", encoding="utf-8")
print(f"GDDR6 source -> {destination}")
PY
chmod 0700 "$gddr6_cmd"
sudo -u "$TARGET_USER" env \
  HOME="$HOME_DIR" USER="$TARGET_USER" LOGNAME="$TARGET_USER" \
  XDG_CONFIG_HOME="$HOME_DIR/.config" \
  XDG_DATA_HOME="$HOME_DIR/.local/share" \
  XDG_CACHE_HOME="$HOME_DIR/.cache" \
  bash "$gddr6_cmd"

echo
echo "[4/6] Installing BC250 Control Center's own pinned FSR4 OptiScaler Client..."
sudo -u "$TARGET_USER" env \
  HOME="$HOME_DIR" USER="$TARGET_USER" LOGNAME="$TARGET_USER" \
  PYTHONPATH="$CC_ROOT/src" \
  python3 - "$fsr4_cmd" <<'PY'
from pathlib import Path
import sys
from bc250cc.infrastructure.sistema_repository import SistemaRepository

repo = SistemaRepository()
repo._abrir_terminal = lambda command, title="": (title, command)
result = repo.gestionar_fsr4_bc250("install")
if isinstance(result, tuple) and len(result) == 2:
    title, command = result
else:
    raise SystemExit(f"Unexpected FSR4 backend result: {result!r}")
Path(sys.argv[1]).write_text(command + "\n", encoding="utf-8")
print(title or "BC250 OptiScaler Client install")
PY
chmod 0700 "$fsr4_cmd"

sudo -u "$TARGET_USER" env \
  HOME="$HOME_DIR" USER="$TARGET_USER" LOGNAME="$TARGET_USER" \
  XDG_CONFIG_HOME="$HOME_DIR/.config" \
  XDG_DATA_HOME="$HOME_DIR/.local/share" \
  XDG_CACHE_HOME="$HOME_DIR/.cache" \
  bash "$fsr4_cmd"


echo
echo "[5/6] Re-applying GFX1013 async RADV after OptiScaler Client installation..."
echo "User-validated ordering: OptiScaler/FSR4 first, async RADV repair/update last."
sudo -u "$TARGET_USER" env \
  HOME="$HOME_DIR" USER="$TARGET_USER" LOGNAME="$TARGET_USER" \
  PYTHONPATH="$CC_ROOT/src" \
  python3 - "$async_cmd" <<'PY'
from pathlib import Path
import sys
from bc250cc.infrastructure.sistema_repository import SistemaRepository

repo = SistemaRepository()
repo._abrir_terminal = lambda command, title="": (title, command)
result = repo.gestionar_gfx1013_bazzite("install")
if not (isinstance(result, tuple) and len(result) == 2):
    raise SystemExit(f"Unexpected GFX1013 backend result: {result!r}")
title, command = result
Path(sys.argv[1]).write_text(command + "\n", encoding="utf-8")
print(title or "GFX1013 async compute repair/update")
PY
chmod 0700 "$async_cmd"

sudo -u "$TARGET_USER" env \
  HOME="$HOME_DIR" USER="$TARGET_USER" LOGNAME="$TARGET_USER" \
  XDG_CONFIG_HOME="$HOME_DIR/.config" \
  XDG_DATA_HOME="$HOME_DIR/.local/share" \
  XDG_CACHE_HOME="$HOME_DIR/.cache" \
  bash "$async_cmd"

command -v bc250-async-compute >/dev/null 2>&1 || {
  echo "ERROR: async repair/update completed but bc250-async-compute is missing." >&2
  exit 31
}
sudo bc250-async-compute always enable

echo "Verifying repaired async RADV through BC250 Control Center backend..."
sudo -u "$TARGET_USER" env \
  HOME="$HOME_DIR" USER="$TARGET_USER" LOGNAME="$TARGET_USER" \
  PYTHONPATH="$CC_ROOT/src" \
  python3 - <<'PY'
from bc250cc.infrastructure.bazzite_async_compute import probe_bazzite_async_compute

state = probe_bazzite_async_compute()
print("Async state:", state.get("bazzite_async_state"))
print("Current payload:", bool(state.get("bazzite_async_current")))
print("Always-on enabled:", bool(state.get("bazzite_async_enabled")))
print("Current session active:", bool(state.get("bazzite_async_session_active")))
if not state.get("bazzite_async_current"):
    raise SystemExit("ERROR: repaired async RADV payload is not current")
if not state.get("bazzite_async_enabled"):
    raise SystemExit("ERROR: async RADV is not enabled system-wide")
PY

echo
echo "[6/6] Read-back through BC250 Control Center inventory..."
sudo -u "$TARGET_USER" env \
  HOME="$HOME_DIR" USER="$TARGET_USER" LOGNAME="$TARGET_USER" \
  PYTHONPATH="$CC_ROOT/src" \
  python3 - <<'PY'
from bc250cc.infrastructure.sistema_repository import SistemaRepository
from bc250cc.infrastructure.bc250_opticlient import opticlient_state

repo = SistemaRepository()
tools = repo.estado_herramientas_bc250()
components = dict(tools.get("prepare_components") or {})
labels = {
    "runtime": "Base dependencies",
    "governor": "Selected GPU governor",
    "cpu_oc": "CPU OC tools",
    "core_unlock": "CPU Core Unlock source",
    "umr": "UMR database",
    "cu_manager": "40CU manager",
    "fan_pwm": "NCT sensors and PWM",
}
failed = []
for key, label in labels.items():
    ready = bool(dict(components.get(key) or {}).get("installed"))
    print(f"[{'OK' if ready else 'MISS'}] {label}")
    if not ready:
        failed.append(label)

fsr4 = opticlient_state()
client_ready = bool(fsr4.get("current"))
print(f"[{'OK' if client_ready else 'MISS'}] FSR4 INT8 OptiScaler Client")
if not client_ready:
    failed.append("FSR4 INT8 OptiScaler Client")

external = dict(tools.get("external_integrations") or {})
gddr6 = dict(external.get("gddr6_memory_temp") or {})
gddr6_ready = bool(gddr6.get("source_verified") or gddr6.get("verified"))
print(f"[{'OK' if gddr6_ready else 'MISS'}] GDDR6 reviewed checkout")
print("     ", gddr6 or "no inventory entry")
if not gddr6_ready:
    failed.append("GDDR6 reviewed checkout")

if failed:
    print()
    print("Control Center inventory still reports missing:")
    for item in failed:
        print("  -", item)
    raise SystemExit(30)

print()
print("BC250 Control Center inventory synchronization: PASS")
PY

echo
echo "=== BC250 CONTROL CENTER INVENTORY SYNC COMPLETE ==="

if [[ "$GUI_WAS_RUNNING" -eq 1 ]]; then
  echo "Restarting BC250 Control Center so the GUI drops its cached inventory..."
  mapfile -t gui_pids < <(bc250cc_gui_pids)
  if ((${#gui_pids[@]})); then
    kill -TERM "${gui_pids[@]}" 2>/dev/null || true
  fi
  for _ in {1..30}; do
    [[ -z "$(bc250cc_gui_pids)" ]] && break
    sleep 0.25
  done
  if [[ -n "$(bc250cc_gui_pids)" ]]; then
    mapfile -t gui_pids < <(bc250cc_gui_pids)
    kill -KILL "${gui_pids[@]}" 2>/dev/null || true
    sleep 0.5
  fi

  launcher="/usr/local/bin/bc250-control-center"
  [[ -x "$launcher" ]] || launcher="/usr/bin/bc250-control-center"
  log="$HOME_DIR/.cache/bc250-framework/bc250cc-relaunch.log"
  install -d -o "$USER_UID" -g "$(id -g "$TARGET_USER")" -m 0755 "$(dirname "$log")"
  sudo -u "$TARGET_USER" env \
    HOME="$HOME_DIR" USER="$TARGET_USER" LOGNAME="$TARGET_USER" \
    DISPLAY="${DISPLAY:-}" WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-}" \
    XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$USER_UID}" \
    DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/$USER_UID/bus}" \
    nohup "$launcher" >"$log" 2>&1 &
  for _ in {1..20}; do
    [[ -n "$(bc250cc_gui_pids)" ]] && break
    sleep 0.25
  done
  if [[ -n "$(bc250cc_gui_pids)" ]]; then
    echo "BC250 Control Center restarted with fresh inventory."
  else
    echo "WARNING: automatic GUI relaunch did not appear; open BC250 Control Center manually." >&2
    echo "Relaunch log: $log" >&2
  fi
else
  echo "BC250 Control Center was not running; open it now to see the refreshed inventory."
fi

echo "The Components page should show · Ready for detected components."
echo "The OptiScaler Client card should show Installed."
echo "GFX1013 async RADV was deliberately repaired AFTER OptiScaler and re-enabled always-on."
echo
echo "Note: the FSR4 Lutris policy remains a separate setup layer: it decides which Lutris games"
echo "are Linux-confirmed compatible and sets protonge-latest-bc250 + FSR4 ENV only there."
