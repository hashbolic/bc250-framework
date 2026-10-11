#!/usr/bin/env python3
"""Read-only BC250 FSR4 provider audit.

Do not infer an active provider from installed Proton or DLL files alone.
Runtime identity is established only for a file mapped by Cyberpunk's process.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path

RC11_SHA256 = "8192ea97620f8e6407bff346bf905f0d555ff73d89fe14616eb1fa5e41ab3175"
RC11_SIZE = 94840832
WANTED = ("amd_fidelityfx_upscaler_dx12.dll", "amdxcffx64.dll", "optiscaler",
          "fsr411f", "fidelityfx")
RUNNER = "protonge-latest-bc250"


def sha256(path: Path) -> str:
    result = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def file_identity(path: Path) -> tuple[str, str]:
    try:
        stat = path.stat()
        if not stat.is_file():
            return "unavailable", "mapped path not a regular file"
        if stat.st_size > 250_000_000:
            return "unavailable", "file too large for FSR4 DLL probe"
        digest = sha256(path)
        if digest == RC11_SHA256:
            return "RC11", "exact release DLL SHA256"
        if path.name.lower() == "amd_fidelityfx_upscaler_dx12.dll":
            return "other/unknown", f"size={stat.st_size}, sha256={digest}"
        return "other/unknown", f"size={stat.st_size}, sha256={digest}"
    except (OSError, PermissionError) as e:
        return "unavailable", str(e)


def active_games():
    found = []
    for proc in Path("/proc").iterdir():
        if not proc.name.isdecimal():
            continue
        try:
            command = (proc / "cmdline").read_bytes().replace(b"\0", b" ").decode(errors="replace")
            if "cyberpunk2077" not in command.lower():
                continue
        except (OSError, PermissionError):
            continue
        found.append((proc, command))
    return found


def mapped_providers(proc: Path):
    try:
        lines = (proc / "maps").read_text(encoding="utf-8", errors="replace").splitlines()
    except (OSError, PermissionError):
        return None
    paths = set()
    for line in lines:
        name = line.split(maxsplit=5)
        if len(name) < 6 or not name[5].startswith("/"):
            continue
        candidate = name[5].removesuffix(" (deleted)")
        low = candidate.lower()
        if any(token in low for token in WANTED) and low.endswith((".dll", ".so")):
            paths.add(candidate)
    return sorted(paths)


def installed_runner():
    home = Path.home()
    roots = (
        home / ".local/share/Steam/compatibilitytools.d",
        home / ".steam/root/compatibilitytools.d",
        home / ".steam/steam/compatibilitytools.d",
    )
    for root in roots:
        path = root / RUNNER
        if not path.is_dir():
            continue
        config = path / "bc250-fsr4-config.json"
        if config.exists():
            try:
                obj = json.loads(config.read_text(encoding="utf-8"))
                return str(path), "fsr411f" in json.dumps(obj).lower()
            except (OSError, ValueError):
                return str(path), False
        return str(path), False
    return None, False


def main():
    print("=== BC250 FSR4 DOCTOR (read-only) ===")
    print(f"Known RC11 DLL SHA256: {RC11_SHA256}")
    runner, selects_rc11 = installed_runner()
    print(f"Installed special Proton: {runner or 'NOT FOUND'}")
    print(f"RC11 fsr411f selector configured: {'YES' if selects_rc11 else 'NO / UNKNOWN'}")
    print("NOTE: installed/configured is NOT the same as active in Cyberpunk.")
    running = active_games()
    if not running:
        print("\nACTIVE RC11: UNVERIFIED (Cyberpunk is not running)")
        print("Start Cyberpunk, enter gameplay with FSR4 selected, and run bc fsr4 doctor again.")
        print("Also check OptiScaler overlay: expected version 4.1.1r11, source LOCAL.")
        return
    seen = False
    exact = False
    print("\nCyberpunk processes discovered:")
    for proc, command in running:
        print(f"PID {proc.name}: {command[:230]}")
        mapped = mapped_providers(proc)
        if mapped is None:
            print("  /proc maps inaccessible; live DLL identity UNKNOWN")
            continue
        if not mapped:
            print("  No recognizable FSR DLLs mapped in this process")
            continue
        for raw in mapped:
            path = Path(raw)
            label, details = file_identity(path)
            print(f"  [{label}] {raw}")
            print(f"    {details}")
            seen = True
            if label == "RC11":
                exact = True
    if exact:
        print("\nACTIVE RC11 DLL: CONFIRMED by exact mapped-file SHA256.")
    elif seen:
        print("\nACTIVE RC11 DLL: NOT CONFIRMED. Inspect mapped providers and OptiScaler overlay.")
    else:
        print("\nACTIVE RC11 DLL: UNVERIFIED. The game can load DLLs through another helper process.")
    print("Only mapped RC11 DLL SHA256 proves the exact release binary; fsr411f alone does not.")
    print("OptiScaler overlay: version 4.1.1r11, source LOCAL, and model INT8 must be checked.")


if __name__ == "__main__":
    main()
