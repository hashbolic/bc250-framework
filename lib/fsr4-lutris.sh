#!/usr/bin/env bash
set -Eeuo pipefail

echo "=== BC250 Framework: selective FSR4 for verified Lutris games ==="
echo
echo "Primary source: live OptiScaler Compatibility List."
echo "Policy: auto-switch only positive entries with explicit Linux evidence."
echo "Unknown, risky and Windows-only-evidence games stay unchanged."
echo

TARGET_USER="${SUDO_USER:-${USER:-}}"
if [[ -z "$TARGET_USER" || "$TARGET_USER" == root ]] || ! id "$TARGET_USER" >/dev/null 2>&1; then
  TARGET_USER="$(getent passwd 1000 | cut -d: -f1 || true)"
fi
[[ -n "$TARGET_USER" ]] || { echo "ERROR: desktop user not found." >&2; exit 2; }

HOME_DIR="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
USER_UID="$(id -u "$TARGET_USER")"
RUNNER_NAME="protonge-latest-bc250"
RUNNER_LINK="$HOME_DIR/.local/share/lutris/runners/wine/$RUNNER_NAME"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_ROOT="$HOME_DIR/.local/share/bc250-framework/lutris-backups/$STAMP"
CACHE_ROOT="$HOME_DIR/.cache/bc250-framework"
WIKI_CACHE="$CACHE_ROOT/optiscaler-wiki"
WIKI_PAGE="$WIKI_CACHE/Compatibility-List.md"
WIKI_URL="https://github.com/optiscaler/OptiScaler.wiki.git"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MATCHER="$HERE/helpers/optiscaler_lutris_selective.py"

find_tool() {
  local d
  for d in \
    "$HOME_DIR/.local/share/Steam/compatibilitytools.d/$RUNNER_NAME" \
    "$HOME_DIR/.steam/root/compatibilitytools.d/$RUNNER_NAME" \
    "$HOME_DIR/.steam/steam/compatibilitytools.d/$RUNNER_NAME"; do
    [[ -d "$d" && -f "$d/proton" && -x "$d/files/bin/wine" ]] && {
      printf '%s\n' "$d"
      return 0
    }
  done
  return 1
}

TOOL="$(find_tool || true)"
[[ -n "$TOOL" ]] || {
  echo "ERROR: $RUNNER_NAME is not installed. Run bc setup first." >&2
  exit 3
}
[[ -x "$MATCHER" || -r "$MATCHER" ]] || {
  echo "ERROR: compatibility matcher is missing: $MATCHER" >&2
  exit 4
}

if [[ ! -L "$RUNNER_LINK" || "$(readlink -f "$RUNNER_LINK" 2>/dev/null || true)" != "$(readlink -f "$TOOL")" ]]; then
  [[ -x /usr/libexec/bc250-register-fsr4-lutris ]] || {
    echo "ERROR: Lutris registration helper is missing." >&2
    exit 5
  }
  echo "Registering $RUNNER_NAME in Lutris..."
  sudo /usr/libexec/bc250-register-fsr4-lutris "$TARGET_USER" "$TOOL"
fi

[[ -x "$RUNNER_LINK/files/bin/wine" ]] || {
  echo "ERROR: Lutris runner link is invalid: $RUNNER_LINK" >&2
  exit 6
}

command -v git >/dev/null 2>&1 || {
  echo "ERROR: git is required to refresh OptiScaler compatibility data." >&2
  exit 7
}

echo "Refreshing OptiScaler compatibility data..."
sudo -u "$TARGET_USER" mkdir -p "$CACHE_ROOT"
if [[ -d "$WIKI_CACHE/.git" ]]; then
  if sudo -u "$TARGET_USER" env HOME="$HOME_DIR" git -C "$WIKI_CACHE" fetch --quiet --depth 1 origin HEAD; then
    sudo -u "$TARGET_USER" env HOME="$HOME_DIR" git -C "$WIKI_CACHE" reset --quiet --hard FETCH_HEAD
  else
    echo "WARNING: online refresh failed; using cached compatibility data." >&2
  fi
else
  rm -rf "$WIKI_CACHE"
  sudo -u "$TARGET_USER" env HOME="$HOME_DIR" git clone --quiet --depth 1 "$WIKI_URL" "$WIKI_CACHE" || {
    echo "ERROR: could not download OptiScaler compatibility data." >&2
    exit 8
  }
fi

[[ -r "$WIKI_PAGE" ]] || {
  echo "ERROR: Compatibility-List.md is missing from OptiScaler wiki cache." >&2
  exit 9
}

WIKI_COMMIT="$(git -C "$WIKI_CACHE" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
WIKI_UPDATED="$(sed -nE 's/.*Last updated[[:space:]]*[–-][[:space:]]*(.*)/\1/p' "$WIKI_PAGE" | head -n1 || true)"
echo "OptiScaler wiki commit: $WIKI_COMMIT"
[[ -n "$WIKI_UPDATED" ]] && echo "List date: $WIKI_UPDATED"

if pgrep -u "$USER_UID" -f '(^|/)lutris([[:space:]]|$)' >/dev/null 2>&1; then
  echo "Closing Lutris before editing verified game configs..."
  pkill -TERM -u "$USER_UID" -f '(^|/)lutris([[:space:]]|$)' 2>/dev/null || true
  for _ in {1..20}; do
    pgrep -u "$USER_UID" -f '(^|/)lutris([[:space:]]|$)' >/dev/null 2>&1 || break
    sleep 0.25
  done
fi

sudo -u "$TARGET_USER" mkdir -p "$BACKUP_ROOT"
sudo -u "$TARGET_USER" env HOME="$HOME_DIR" python3 "$MATCHER" \
  "$HOME_DIR" "$RUNNER_NAME" "$WIKI_PAGE" "$BACKUP_ROOT"

if [[ -d "$BACKUP_ROOT" ]] && ! find "$BACKUP_ROOT" -type f -print -quit | grep -q .; then
  rmdir -p --ignore-fail-on-non-empty "$BACKUP_ROOT" 2>/dev/null || true
  BACKUP_ROOT=""
fi

echo
echo "=== SELECTIVE LUTRIS FSR4 DEPLOYMENT COMPLETE ==="
echo "Runner: $RUNNER_NAME"
echo "OptiScaler source: $WIKI_COMMIT"
if [[ -n "$BACKUP_ROOT" ]]; then
  echo "Backup: $BACKUP_ROOT"
else
  echo "Backup: not needed"
fi
echo
echo "Only Linux-confirmed compatible games were auto-switched."
echo "Verified games also receive explicit Lutris ENV:"
echo "  PROTON_FSR4_UPGRADE=4.1.1"
echo "  PROTON_USE_OPTISCALER=1"
echo "Restart Lutris before launching a changed game."
