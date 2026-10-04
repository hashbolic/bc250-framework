#!/usr/bin/env bash
set -Eeuo pipefail

STATE=/var/lib/bc250-framework/cu-test
GOOD="$STATE/good-wgps"
BAD="$STATE/bad-wgps"
PENDING="$STATE/pending"
RESULT="$STATE/result.env"
CANDIDATES=(0.0.3 0.0.4 0.1.0 0.1.4 1.0.3 1.0.4 1.1.3 1.1.4)

die(){ echo "bc cu-test: $*" >&2; exit 1; }
say(){ printf '%s\n' "$*"; }
contains(){ grep -Fxq "$1" "$2" 2>/dev/null; }
append_unique(){ contains "$1" "$2" || printf '%s\n' "$1" | sudo tee -a "$2" >/dev/null; }

manager="$(command -v bc250-cu-live-manager || true)"
[[ -x "$manager" ]] || die "bc250-cu-live-manager is missing"
lspci -Dn 2>/dev/null | grep -qi '1002:13fe' || die "BC-250 not detected"
flatpak info com.geeks3d.furmark >/dev/null 2>&1 || die "FurMark Flatpak com.geeks3d.furmark is not installed"

verifier=""
for v in /usr/share/bc250-40cu/vendor/bc250-40cu-unlock/scripts/bc250-compute-verify.sh /opt/bc250-40cu-unlock/scripts/bc250-compute-verify.sh; do
  [[ -x "$v" ]] && { verifier="$v"; break; }
done
[[ -n "$verifier" ]] || die "BC250 compute verifier is missing"

sudo install -d -m 0755 "$STATE"
sudo touch "$GOOD" "$BAD"
sudo chmod 0644 "$GOOD" "$BAD"

restore_stock(){ sudo "$manager" --yes stock-dispatch >/dev/null 2>&1 || true; }
cu_total(){
  "$manager" status 2>&1 | sed -nE 's/.*SPI total[[:space:]]*:[[:space:]]*([0-9]+)\/40 CUs.*/\1/p' | tail -n1
}
mark_pending(){ printf '%s\n' "$1" | sudo tee "$PENDING" >/dev/null; sync; }
clear_pending(){ sudo rm -f "$PENDING"; }

manual_furmark(){
  local label="$1"
  echo
  echo "============================================================"
  echo "FurMark visual check: $label"
  echo "============================================================"
  echo "1. FurMark will open now."
  echo "2. Select Vulkan and 1920x1080 (or the display native 1080p mode)."
  echo "3. Run the stress test for about 60 seconds."
  echo "4. Watch for flashing pixels, colored blocks/triangles, corruption or driver reset."
  echo "5. Close FurMark when finished; this wizard will continue."
  read -r -p "Press ENTER to launch FurMark..." </dev/tty
  sudo -u "${SUDO_USER:-$USER}" flatpak run com.geeks3d.furmark || true
  local answer
  while true; do
    read -r -p "Were ANY visual artifacts or a GPU reset observed? [y/N]: " answer </dev/tty
    case "$answer" in
      y|Y|yes|YES|Yes) return 1 ;;
      n|N|no|NO|No|'') return 0 ;;
      *) echo "Please answer y or n." ;;
    esac
  done
}

persist_layout(){
  local cu="$1" method="$2"
  sudo "$manager" --yes write-service-table
  sudo "$manager" --yes install-service
  now="$(cu_total || true)"
  [[ "$now" == "$cu" ]] || die "layout changed during persistence (expected $cu, got ${now:-unknown})"
  masks="$(sed -nE 's/^BC250_WGP_MASKS=//p' /etc/bc250-cu-live-manager.conf 2>/dev/null | tail -n1)"
  {
    echo "qualified=$(date -Is)"
    echo "cu=$cu"
    echo "method=$method"
    echo "masks=$masks"
  } | sudo tee "$RESULT" >/dev/null
  clear_pending
  echo
  echo "CU qualification PASS: $cu CU persisted ($masks)"
}

# Crash/reboot recovery: whichever risky layout was pending is not trusted.
if [[ -s "$PENDING" ]]; then
  p="$(cat "$PENDING")"
  echo "Previous CU test '$p' did not finish. Treating it as unstable."
  case "$p" in
    wgp:*) append_unique "${p#wgp:}" "$BAD" ;;
    final36)
      sudo touch "$STATE/final36-failed"
      restore_stock
      clear_pending
      die "final 36CU layout crashed/rebooted; nothing was persisted"
      ;;
    full40) sudo touch "$STATE/full40-failed" ;;
  esac
  clear_pending
  restore_stock
fi

echo "=== BC250 interactive CU/WGP qualification ==="
echo "Nothing is persisted until automated compute checks AND the FurMark visual check pass."
echo "Policy: 40CU if fully clean; otherwise select a balanced 36CU layout."
echo "38CU is intentionally not used in production."
echo

[[ ! -e "$STATE/final36-failed" ]] ||
  die "a previous final 36CU combined test failed; engineering review/reset is required"

# Full 40CU first.
if [[ ! -e "$STATE/full40-failed" ]]; then
  restore_stock
  mark_pending full40
  echo "Testing all 40 CU..."
  if sudo "$manager" --yes enable all && [[ "$(cu_total)" == 40 ]] && sudo "$verifier"; then
    if manual_furmark "40 CU full layout"; then
      clear_pending
      persist_layout 40 "full40-furmark"
      exit 0
    fi
    echo "40CU showed artifacts; switching to per-WGP isolation."
  else
    echo "40CU automated compute verification failed; switching to per-WGP isolation."
  fi
  sudo touch "$STATE/full40-failed"
  clear_pending
  restore_stock
fi

# Test each factory-disabled WGP in isolation on top of stock 24CU.
for wgp in "${CANDIDATES[@]}"; do
  contains "$wgp" "$GOOD" && continue
  contains "$wgp" "$BAD" && continue

  restore_stock
  mark_pending "wgp:$wgp"
  echo
  echo "Testing WGP $wgp (stock 24CU + 2CU candidate)..."
  if ! sudo "$manager" --yes enable-wgp "$wgp"; then
    echo "WGP $wgp could not be enabled -> BAD"
    append_unique "$wgp" "$BAD"; clear_pending; restore_stock; continue
  fi
  [[ "$(cu_total)" == 26 ]] || {
    echo "WGP $wgp produced unexpected CU count -> BAD"
    append_unique "$wgp" "$BAD"; clear_pending; restore_stock; continue
  }
  if ! sudo "$verifier"; then
    echo "WGP $wgp failed automated compute verification -> BAD"
    append_unique "$wgp" "$BAD"; clear_pending; restore_stock; continue
  fi
  if manual_furmark "WGP $wgp / 26CU isolated layout"; then
    echo "WGP $wgp visually clean -> GOOD"
    append_unique "$wgp" "$GOOD"
  else
    echo "WGP $wgp showed artifacts -> BAD"
    append_unique "$wgp" "$BAD"
  fi
  clear_pending
  restore_stock
done

mapfile -t se0 < <(grep '^0\.' "$GOOD" 2>/dev/null || true)
mapfile -t se1 < <(grep '^1\.' "$GOOD" 2>/dev/null || true)

echo
echo "Qualified extra WGPs:"
echo "  SE0: ${se0[*]:-none}"
echo "  SE1: ${se1[*]:-none}"
echo "Bad/unstable WGPs:"
sed 's/^/  /' "$BAD" 2>/dev/null || true

(("${#se0[@]}" >= 3 && "${#se1[@]}" >= 3)) || {
  restore_stock
  die "not enough balanced good WGPs for production 36CU (need at least 3 good in each SE)"
}

# Deliberately select exactly three per shader engine => balanced 36CU.
selected=("${se0[0]}" "${se0[1]}" "${se0[2]}" "${se1[0]}" "${se1[1]}" "${se1[2]}")
restore_stock
mark_pending final36
sudo "$manager" --yes enable-wgp "${selected[@]}"
[[ "$(cu_total)" == 36 ]] || { clear_pending; restore_stock; die "selected balanced layout did not produce 36CU"; }

echo
echo "Final production candidate: 36CU"
echo "Selected WGPs: ${selected[*]}"
sudo "$verifier" || { clear_pending; restore_stock; die "final 36CU compute verification failed"; }
if ! manual_furmark "FINAL balanced 36CU layout"; then
  sudo touch "$STATE/final36-failed"
  clear_pending
  restore_stock
  die "final 36CU layout showed artifacts; nothing was persisted"
fi

clear_pending
persist_layout 36 "balanced36-furmark"
