#!/usr/bin/env bash
set -Eeuo pipefail

ACTION="${1:-configure}"
TARGET_USER="${BC250_TARGET_USER:-${SUDO_USER:-${USER:-}}}"
if [[ -z "$TARGET_USER" || "$TARGET_USER" == root ]] || ! id "$TARGET_USER" >/dev/null 2>&1; then
  TARGET_USER="$(getent passwd 1000 | cut -d: -f1 || true)"
fi
[[ -n "$TARGET_USER" ]] || { echo "bc control-center: desktop user not found" >&2; exit 3; }

HOME_DIR="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
USER_UID="$(id -u "$TARGET_USER")"
USER_GID="$(id -g "$TARGET_USER")"
BUNDLED_ROOT="/usr/share/bc250-control-center"
LOCAL_PREFIX="$HOME_DIR/.local"
LOCAL_ROOT="$LOCAL_PREFIX/share/bc250-control-center"
LOCAL_BIN="$LOCAL_PREFIX/bin"
LOCAL_APPS="$LOCAL_PREFIX/share/applications"
LOCAL_SYSTEMD="$HOME_DIR/.config/systemd/user"
DESKTOP_ID="io.github.movacx.bc250-control-center.desktop"
SERVICE="bc250-control-centerd.service"
CFG_DIR="$HOME_DIR/.config/bc250-control-center"
BACKUP_DIR="$HOME_DIR/.local/share/bc250-framework/backups/control-center"

die(){ echo "bc control-center: $*" >&2; exit 1; }
ok(){ printf '[ OK ] %s\n' "$*"; }
warn(){ printf '[WARN] %s\n' "$*" >&2; }

run_user(){
  if [[ "$(id -u)" -eq "$USER_UID" ]]; then
    HOME="$HOME_DIR" USER="$TARGET_USER" LOGNAME="$TARGET_USER" "$@"
  else
    sudo -u "$TARGET_USER" env HOME="$HOME_DIR" USER="$TARGET_USER" LOGNAME="$TARGET_USER" "$@"
  fi
}

bundled_version(){ cat "$BUNDLED_ROOT/VERSION" 2>/dev/null || echo unknown; }
local_version(){ cat "$LOCAL_ROOT/VERSION" 2>/dev/null || true; }

backup_config(){
  [[ -d "$CFG_DIR" ]] || return 0
  local stamp dest
  stamp="$(date +%Y%m%d-%H%M%S)"
  dest="$BACKUP_DIR/$stamp"
  run_user mkdir -p "$dest"
  run_user cp -a "$CFG_DIR/." "$dest/"
  ok "Control Center config backup: $dest"
}

seed(){
  [[ -f "$BUNDLED_ROOT/frontends/desktop/main.py" ]] || die "bundled upstream Control Center is missing"
  local current bundled
  current="$(local_version)"
  bundled="$(bundled_version)"

  if [[ -n "$current" ]]; then
    echo "Upstream Control Center user-local runtime already present: $current"
  else
    echo "Seeding upstream Control Center $bundled into $LOCAL_ROOT ..."
    run_user mkdir -p "$LOCAL_PREFIX/share" "$LOCAL_BIN" "$LOCAL_APPS" "$LOCAL_SYSTEMD"
    run_user rm -rf "$LOCAL_ROOT.new"
    run_user mkdir -p "$LOCAL_ROOT.new"
    run_user cp -a "$BUNDLED_ROOT/." "$LOCAL_ROOT.new/"
    run_user mv "$LOCAL_ROOT.new" "$LOCAL_ROOT"
  fi

  # The launchers themselves are unmodified upstream launchers. Installed
  # under ~/.local/bin, their first relative runtime candidate is ~/.local/share.
  for launcher in bc250-control-center bc250-control-center-cli bc250-control-centerd; do
    [[ -x "/usr/bin/$launcher" ]] || die "upstream launcher /usr/bin/$launcher is missing"
    run_user install -m 0755 "/usr/bin/$launcher" "$LOCAL_BIN/$launcher"
  done

  [[ -r "/usr/share/applications/$DESKTOP_ID" ]] || die "upstream desktop entry is missing"
  run_user install -m 0644 "/usr/share/applications/$DESKTOP_ID" "$LOCAL_APPS/$DESKTOP_ID"
  run_user sed -i "s|^Exec=.*|Exec=$LOCAL_BIN/bc250-control-center|" "$LOCAL_APPS/$DESKTOP_ID"

  [[ -r "/usr/lib/systemd/user/$SERVICE" ]] || die "upstream user service is missing"
  run_user install -m 0644 "/usr/lib/systemd/user/$SERVICE" "$LOCAL_SYSTEMD/$SERVICE"
  run_user sed -i "s|^ExecStart=.*|ExecStart=$LOCAL_BIN/bc250-control-centerd|" "$LOCAL_SYSTEMD/$SERVICE"

  if [[ -d /run/systemd/system ]]; then
    run_user systemctl --user daemon-reload || true
    run_user systemctl --user enable --now "$SERVICE" || warn "Control Center daemon will start on next user login."
    if [[ -r /usr/lib/systemd/user/bc250-steam-shortcuts.timer ]]; then
      run_user systemctl --user enable --now bc250-steam-shortcuts.timer ||
        warn "Steam shortcut retry timer will be enabled on next setup/login."
    fi
  fi

  ok "Upstream Control Center runtime is independent from the immutable image"
}

configure(){
  seed
  backup_config
  run_user mkdir -p "$CFG_DIR"

  run_user python3 - "$CFG_DIR" <<'PY'
import json
import os
import tempfile
from pathlib import Path

root = Path(__import__("sys").argv[1])
root.mkdir(parents=True, exist_ok=True)

def read(path, default):
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
        return value if isinstance(value, dict) else dict(default)
    except (OSError, ValueError):
        return dict(default)

def atomic_json(path, value):
    fd, tmp = tempfile.mkstemp(prefix="."+path.name+".", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(value, stream, indent=2, ensure_ascii=False, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(tmp, path)
    finally:
        try: os.unlink(tmp)
        except FileNotFoundError: pass

config_path = root / "config.json"
config = read(config_path, {})
config.update({
    "version": 2,
    "idioma": config.get("idioma", "auto"),
    "tema": config.get("tema", "dark"),
    "alertas_activas": False,
    "modo_discreto": config.get("modo_discreto", True),
    "gpu_governor": "cyan-skillfish-governor-smu",
    "daemon_interval_seconds": config.get("daemon_interval_seconds", 2),
})
config.setdefault("fan_curve", {
    "enabled": False,
    "edit_enabled": False,
    "pwm": 2,
    "t1": 45, "s1": 15,
    "t2": 60, "s2": 30,
    "t3": 75, "s3": 50,
    "point_count": 4,
    "points": [
        {"temperature": 45, "speed": 15},
        {"temperature": 60, "speed": 30},
        {"temperature": 75, "speed": 50},
        {"temperature": 85, "speed": 100},
    ],
    "preset": "external-coolercontrol",
    "last_pwm_text": "--",
})
config.setdefault("fan_preset", {
    "enabled": False,
    "preset": "external-coolercontrol",
    "percent": 0,
    "pwm": 2,
})
atomic_json(config_path, config)

profiles_path = root / "perfiles.json"
profiles = read(profiles_path, {})
profiles["version"] = 1
profiles["gpu"] = {
    "economy": {"min": 500, "max": 1600, "frequency": 1600, "voltage": 800, "descripcion": "BC250 Economy"},
    "gaming": {"min": 500, "max": 1850, "frequency": 1850, "voltage": 925, "descripcion": "BC250 Gaming"},
    "maximum": {"min": 500, "max": 1970, "frequency": 1970, "voltage": 975, "descripcion": "BC250 Maximum"},
}
profiles["cpu"] = {
    "economy": {"frequency": 3600, "vid": 1050, "scale": -30, "temp": 85},
    "gaming": {"frequency": 3700, "vid": 1145, "scale": -24, "temp": 85},
    "performance": {"frequency": 3800, "vid": 1200, "scale": -25, "temp": 85},
}
atomic_json(profiles_path, profiles)
PY

  # Write only the profile slots/default preferences BC Framework owns. Other
  # user choices stay intact and survive upstream application updates.
  run_user env XDG_CONFIG_HOME="$HOME_DIR/.config" python3 - <<'PY'
from pathlib import Path
from PyQt6.QtCore import QSettings
import os

path = Path(os.environ["XDG_CONFIG_HOME"]) / "bc250-control-center" / "ui.conf"
settings = QSettings(str(path), QSettings.Format.IniFormat)

defaults = {
    "onboarding/completed_version": 1,
    "settings/language": "auto",
    "settings/appearance": "dark",
    "settings/accent": "cyan",
    "settings/density": "comfortable",
    "settings/update_check": "true",
    "settings/gamepad_navigation": "true",
    "settings/gamepad_onscreen_keypad": "true",
}
for key, value in defaults.items():
    if not settings.contains(key):
        settings.setValue(key, value)

gpu = (
    ("Economy", 500, 1600, 1600, 800),
    ("Gaming", 500, 1850, 1850, 925),
    ("Maximum", 500, 1970, 1970, 975),
)
for index, (name, low, high, freq, mv) in enumerate(gpu):
    prefix = f"gpu/cyan_profile_{index}/"
    settings.setValue(prefix + "name", name)
    settings.setValue(prefix + "min", low)
    settings.setValue(prefix + "max", high)
    settings.setValue(prefix + "frequency", freq)
    settings.setValue(prefix + "voltage", mv)

cpu = (
    ("board_average", "Economy", 3600, 1050, 85),
    ("mid_point", "Gaming", 3700, 1145, 85),
    ("safe_maximum", "Performance", 3800, 1200, 85),
)
for index, (key, name, freq, vid, temp) in enumerate(cpu):
    prefix = f"cpu/profile_{index}/"
    settings.setValue(prefix + "key", key)
    settings.setValue(prefix + "name", name)
    settings.setValue(prefix + "frequency", freq)
    settings.setValue(prefix + "vid", vid)
    settings.setValue(prefix + "temperature", temp)

settings.setValue("settings/update_check", "true")
settings.sync()
if settings.status() != QSettings.Status.NoError:
    raise SystemExit("Control Center QSettings sync failed")
PY

  run_user chmod 0700 "$CFG_DIR"
  run_user find "$CFG_DIR" -type f -exec chmod 0600 {} +
  ok "BC Framework profiles/config written to upstream Control Center user data"
}

status(){
  echo "Bundled upstream version: $(bundled_version)"
  echo "User-local version:       $(local_version)"
  echo "Runtime:                  $LOCAL_ROOT"
  echo "Config:                   $CFG_DIR"
  if [[ -f "$LOCAL_ROOT/frontends/desktop/main.py" ]]; then
    ok "independent upstream runtime present"
  else
    warn "user-local runtime not installed; bundled fallback is active"
  fi
}

reset(){
  backup_config
  if [[ -d /run/systemd/system ]]; then
    run_user systemctl --user disable --now "$SERVICE" >/dev/null 2>&1 || true
  fi
  run_user rm -rf "$LOCAL_ROOT"
  run_user rm -f "$LOCAL_BIN/bc250-control-center" "$LOCAL_BIN/bc250-control-center-cli" "$LOCAL_BIN/bc250-control-centerd"
  run_user rm -f "$LOCAL_APPS/$DESKTOP_ID" "$LOCAL_SYSTEMD/$SERVICE"
  run_user rm -rf "$CFG_DIR"
  if [[ -d /run/systemd/system ]]; then
    run_user systemctl --user daemon-reload >/dev/null 2>&1 || true
  fi
  ok "Control Center returned to bundled fallback / pre-setup state"
}

case "$ACTION" in
  seed) seed ;;
  configure) configure ;;
  status) status ;;
  reset) reset ;;
  *) die "usage: control-center.sh [seed|configure|status|reset]" ;;
esac
