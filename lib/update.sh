#!/usr/bin/env bash
set -Eeuo pipefail

ACTION="${1:-update}"
BASE_URL="${BC250_FRAMEWORK_RELEASE_BASE:-https://github.com/hashbolic/bc250-framework/releases/latest/download}"
STATE=/var/lib/bc250-framework
RELEASES="$STATE/releases"
CURRENT="$STATE/current"
PREVIOUS="$STATE/previous"
IDENTITY='^https://github\.com/hashbolic/bc250-framework/\.github/workflows/release\.yml@refs/tags/v[0-9]+\.[0-9]+\.[0-9]+$'
ISSUER='https://token.actions.githubusercontent.com'

die(){ echo "bc update: $*" >&2; exit 1; }

rollback(){
  [[ -L "$PREVIOUS" ]] || die "no previous framework release is available"
  old="$(readlink -f "$PREVIOUS")"
  [[ -d "$old" && -x "$old/setup.sh" ]] || die "previous framework release is invalid"
  cur="$(readlink -f "$CURRENT" 2>/dev/null || true)"
  sudo ln -sfn "$old" "$CURRENT.new"
  sudo mv -Tf "$CURRENT.new" "$CURRENT"
  if [[ -n "$cur" && -d "$cur" ]]; then
    sudo ln -sfn "$cur" "$PREVIOUS.new"
    sudo mv -Tf "$PREVIOUS.new" "$PREVIOUS"
  fi
  echo "BC250 Framework rolled back to $(cat "$old/VERSION" 2>/dev/null || basename "$old")"
}

update(){
  command -v curl >/dev/null || die "curl is missing"
  command -v cosign >/dev/null || die "cosign is missing"
  command -v tar >/dev/null || die "tar is missing"
  command -v zstd >/dev/null || die "zstd is missing"

  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  echo "Checking public BC250 Framework release..."
  curl -fL --retry 4 --retry-all-errors "$BASE_URL/manifest.json" -o "$tmp/manifest.json"

  python3 - "$tmp/manifest.json" >"$tmp/meta.env" <<'PY'
import json, re, shlex, sys
d=json.load(open(sys.argv[1], encoding="utf-8"))
v=str(d.get("version",""))
sha=str(d.get("sha256",""))
if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", v):
    raise SystemExit("invalid version in manifest")
if not re.fullmatch(r"[0-9a-f]{64}", sha):
    raise SystemExit("invalid sha256 in manifest")
print("VERSION="+shlex.quote(v))
print("SHA256="+shlex.quote(sha))
PY
  # shellcheck disable=SC1090
  source "$tmp/meta.env"

  current_ver=""
  [[ -r "$CURRENT/VERSION" ]] && current_ver="$(cat "$CURRENT/VERSION")"
  if [[ "$current_ver" == "$VERSION" ]]; then
    echo "BC250 Framework $VERSION is already current."
    exit 0
  fi

  curl -fL --retry 4 --retry-all-errors "$BASE_URL/bc250-framework.tar.zst" -o "$tmp/framework.tar.zst"
  curl -fL --retry 4 --retry-all-errors "$BASE_URL/bc250-framework.cosign.bundle" -o "$tmp/framework.cosign.bundle"

  actual="$(sha256sum "$tmp/framework.tar.zst" | awk '{print $1}')"
  [[ "$actual" == "$SHA256" ]] || die "SHA256 mismatch"

  cosign verify-blob     --bundle "$tmp/framework.cosign.bundle"     --certificate-identity-regexp "$IDENTITY"     --certificate-oidc-issuer "$ISSUER"     "$tmp/framework.tar.zst" >/dev/null

  stage="$tmp/stage"
  mkdir -p "$stage"
  tar --zstd -xf "$tmp/framework.tar.zst" -C "$stage"
  [[ -x "$stage/bc" && -x "$stage/setup.sh" && -x "$stage/cu-test.sh" &&
      -x "$stage/game.sh" && -x "$stage/reset.sh" && -r "$stage/VERSION" ]] ||
    die "release payload layout is invalid"
  [[ "$(cat "$stage/VERSION")" == "$VERSION" ]] || die "payload VERSION does not match manifest"

  bash -n "$stage/bc" "$stage/setup.sh" "$stage/cu-test.sh" "$stage/game.sh" "$stage/reset.sh" "$stage/lib/"*.sh
  python3 -m py_compile "$stage/helpers/steam_launch_options.py" "$stage/helpers/optiscaler_lutris_selective.py"
  sudo install -d -m 0755 "$RELEASES"
  dest="$RELEASES/$VERSION"
  sudo rm -rf "$dest.new"
  sudo mkdir -p "$dest.new"
  sudo cp -a "$stage/." "$dest.new/"
  sudo mv "$dest.new" "$dest"

  old="$(readlink -f "$CURRENT" 2>/dev/null || true)"
  if [[ -n "$old" && -d "$old" ]]; then
    sudo ln -sfn "$old" "$PREVIOUS.new"
    sudo mv -Tf "$PREVIOUS.new" "$PREVIOUS"
  fi
  sudo ln -sfn "$dest" "$CURRENT.new"
  sudo mv -Tf "$CURRENT.new" "$CURRENT"

  echo "BC250 Framework updated: ${current_ver:-bundled} -> $VERSION"
}

case "$ACTION" in
  update) update ;;
  rollback) rollback ;;
  *) die "usage: update.sh [update|rollback]" ;;
esac
