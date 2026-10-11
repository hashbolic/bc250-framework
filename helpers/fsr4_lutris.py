#!/usr/bin/env python3
"""BC250 FSR4 research: reversible, single-game Lutris environment editor.

Only manipulates native Lutris Cyberpunk 2077 YAML, never global Mesa,
the game executable, Proton or AMD DLLs.
"""
from __future__ import annotations
import hashlib
import json
import os
import re
import sqlite3
import sys
import tempfile
from pathlib import Path

HOME = Path.home()
STATE_DIR = HOME / ".local/share/bc250-framework/fsr4-research"
STATE = STATE_DIR / "lutris-state.json"
BACKUP = STATE_DIR / "cyberpunk-original.yml"
GAME_DIRS = [
    HOME / ".config/lutris/games",
    HOME / ".local/share/lutris/games",
    HOME / ".var/app/net.lutris.Lutris/config/lutris/games",
]
MANAGED = ("VKD3D_SHADER_OVERRIDE", "VKD3D_SHADER_DUMP_PATH", "VK_DRIVER_FILES",
           "MANGOHUD_CONFIGFILE", "MANGOHUD")


def fail(msg):
    raise SystemExit("bc fsr4: " + msg)


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def candidate_games():
    matches = []
    for directory in GAME_DIRS:
        for path in sorted(directory.glob("*.y*ml")):
            if path.is_symlink() or not path.is_file():
                continue
            if "cyberpunk" in path.stem.casefold():
                matches.append(path)
                continue
            try:
                raw = path.read_text(encoding="utf-8")
            except (OSError, UnicodeError):
                continue
            if re.search(r"(?mi)^name:\s*['\"]?cyberpunk\s+2077\b", raw):
                matches.append(path)
    return matches


def find_game():
    paths = candidate_games()
    if not paths:
        fail("Cyberpunk 2077 Lutris config not found (expected native Lutris games YAML).")
    if len(paths) > 1:
        fail("Multiple Cyberpunk configs found; no changes made:\n  " + "\n  ".join(map(str, paths)))
    return paths[0]


def game_id(path):
    for database in (HOME / ".local/share/lutris/pga.db",
                     HOME / ".var/app/net.lutris.Lutris/data/lutris/pga.db"):
        if not database.exists():
            continue
        con = None
        try:
            con = sqlite3.connect(f"file:{database}?mode=ro", uri=True)
            cols = {row[1] for row in con.execute("PRAGMA table_info(games)")}
            if not {"id", "name"}.issubset(cols):
                continue
            rows = con.execute("SELECT id,name," +
                               ("configpath" if "configpath" in cols else "NULL") +
                               " FROM games").fetchall()
            for ident, name, configpath in rows:
                if "cyberpunk" not in str(name).casefold():
                    continue
                configpath = str(configpath or "")
                if configpath and path.stem.casefold() != Path(configpath).stem.casefold():
                    continue
                return str(ident)
        except sqlite3.Error:
            continue
        finally:
            if con is not None:
                con.close()
    return ""


def locate_state():
    if STATE.exists():
        return json.loads(STATE.read_text(encoding="utf-8"))
    return None


def atomic_write(path: Path, payload: bytes):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as f:
        temp = Path(f.name)
        f.write(payload)
        f.flush()
        os.fsync(f.fileno())
    try:
        if path.exists():
            os.chmod(temp, path.stat().st_mode & 0o777)
        else:
            os.chmod(temp, 0o600)
        temp.replace(path)
    finally:
        temp.unlink(missing_ok=True)


def original(path):
    state = locate_state()
    current = path.read_bytes()
    if state:
        if state["path"] != str(path):
            fail("Saved state references another game config; restore it before switching.")
        if digest(current) != state["last_sha256"]:
            fail("Lutris config changed outside FSR4 tool; refusing to overwrite it. Close Lutris and inspect.")
        if not BACKUP.exists() or digest(BACKUP.read_bytes()) != state["original_sha256"]:
            fail("Original backup missing or modified; refusing to overwrite config.")
        return BACKUP.read_bytes(), state
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    atomic_write(BACKUP, current)
    return current, {"path": str(path), "original_sha256": digest(current),
                     "last_sha256": digest(current)}


def system_env_edit(original_text: str, updates: dict[str, str]) -> str:
    lines = original_text.splitlines(keepends=True)
    if any("\t" in line[:len(line)-len(line.lstrip())] for line in lines):
        fail("Unsupported tab-indented YAML; unchanged.")
    starts = [i for i, s in enumerate(lines) if re.match(r"^system:\s*(?:#.*)?$", s.strip("\r\n"))]
    if len(starts) > 1:
        fail("Ambiguous multiple top-level system: entries.")
    if not starts:
        if re.search(r"(?m)^system\s*:", original_text):
            fail("Inline YAML system: mapping unsupported; unchanged.")
        lines.extend(["\n" if lines and not lines[-1].endswith("\n") else "",
                      "system:\n", "  env:\n"])
        env_start = len(lines) - 1
        env_end = len(lines)
        depth = 2
    else:
        start = starts[0]
        end = next((i for i in range(start+1, len(lines))
                    if re.match(r"^[^\s#][^:]*:", lines[i])), len(lines))
        envs = [(i, len(line) - len(line.lstrip()))
                for i, line in enumerate(lines[start+1:end], start+1)
                if re.match(r"^\s+env:\s*(?:#.*)?$", line.rstrip("\r\n"))]
        if len(envs) > 1:
            fail("Ambiguous multiple system.env entries.")
        if not envs:
            if any(re.match(r"^\s+env\s*:", s) for s in lines[start+1:end]):
                fail("Inline system.env mapping unsupported; unchanged.")
            lines.insert(start+1, "  env:\n")
            env_start = start+1
            env_end = start+2
            depth = 2
        else:
            env_start, depth = envs[0]
            env_end = next((i for i in range(env_start+1, end)
                           if lines[i].strip() and not lines[i].lstrip().startswith("#")
                           and len(lines[i]) - len(lines[i].lstrip()) <= depth), end)
    # Refuse conflicting or complex mappings instead of damaging YAML.
    entries = {}
    for i in range(env_start+1, env_end):
        s = lines[i]
        if not s.strip() or s.lstrip().startswith("#"):
            continue
        m = re.match(r"^(\s+)([A-Za-z_][A-Za-z0-9_]*):\s*(.*?)\s*$", s)
        if not m or len(m.group(1)) <= depth:
            fail("Unsupported nested/inline system.env mapping; unchanged.")
        if m.group(2) in MANAGED:
            entries[m.group(2)] = i
    additions = []
    for key, value in updates.items():
        if key not in MANAGED or "'" in value or "\n" in value:
            fail("Invalid managed environment value")
        new_line = " "*(depth+2) + key + ": '" + value + "'\n"
        if key in entries:
            lines[entries[key]] = new_line
        else:
            additions.append(new_line)
    lines[env_start+1:env_start+1] = additions
    return "".join(lines)


def apply(mode: str, extra: str = ""):
    if mode not in ("default", "dump", "cyboman", "v3"):
        fail("expected default, dump, cyboman or v3")
    path = find_game()
    base, state = original(path)
    root = STATE_DIR / "measurements" / mode
    root.mkdir(parents=True, exist_ok=True)
    # Preserve the existing BC250 capsule while adding per-frame capture.
    existing = HOME / ".config/MangoHud/MangoHud.conf"
    settings = existing.read_text(encoding="utf-8") if existing.exists() else ""
    configfile = root / "MangoHud.conf"
    atomic_write(configfile, (settings + "\n"
                 + f"output_folder={root}\nlog_interval=0\n"
                 + "log_duration=0\nbenchmark_percentiles=AVG+1+0.1\n"
                 + "toggle_logging=Shift_L+F2\n").encode())
    values = {"MANGOHUD": "1", "MANGOHUD_CONFIGFILE": str(configfile)}
    if mode == "dump":
        (STATE_DIR / "shader-dump").mkdir(exist_ok=True, parents=True)
        values["VKD3D_SHADER_DUMP_PATH"] = "Z:" + str(STATE_DIR / "shader-dump")
    elif mode == "cyboman":
        folder = Path(extra)
        if not folder.is_absolute() or not any(folder.glob("*.spv")):
            fail("No validated exact SPIR-V override folder found; run dump/build first.")
        values["VKD3D_SHADER_OVERRIDE"] = "Z:" + str(folder)
    elif mode == "v3":
        icd = Path(extra)
        if not icd.is_absolute() or not icd.is_file():
            fail("V3 Vulkan ICD is missing.")
        values["VK_DRIVER_FILES"] = str(icd)
    new_text = system_env_edit(base.decode("utf-8"), values)
    new_bytes = new_text.encode("utf-8")
    atomic_write(path, new_bytes)
    state["last_sha256"] = digest(new_bytes)
    state["mode"] = mode
    atomic_write(STATE, (json.dumps(state, ensure_ascii=False, indent=2) + "\n").encode())
    print(f"[OK] Cyberpunk Lutris mode: {mode}")
    print(f"[OK] Per-game config (backup retained): {path}")
    print(f"[OK] MangoHud logs: {root}")
    ident = game_id(path)
    if ident:
        print(f"LUTRIS_ID={ident}")
    else:
        print("LUTRIS_ID=unknown")
    return ident


def restore():
    state = locate_state()
    if state is None:
        print("No FSR4-managed Lutris changes.")
        return
    path = Path(state["path"])
    if not path.exists() or digest(path.read_bytes()) != state["last_sha256"]:
        fail("Lutris config changed outside tester; refusing unsafe restore.")
    data = BACKUP.read_bytes()
    if digest(data) != state["original_sha256"]:
        fail("Backup checksum mismatch.")
    atomic_write(path, data)
    STATE.unlink()
    print(f"[OK] Original Cyberpunk Lutris config restored: {path}")


def main():
    action = sys.argv[1] if len(sys.argv) > 1 else "status"
    if action == "status":
        print(f"Cyberpunk Lutris config: {find_game()}")
        state = locate_state()
        print(f"Applied benchmark mode: {state.get('mode', 'none') if state else 'none'}")
        print(f"Game ID: {game_id(find_game()) or 'unknown'}")
    elif action == "apply":
        if len(sys.argv) < 3:
            fail("expected apply MODE [ABSOLUTE_PATH]")
        apply(sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else "")
    elif action == "restore":
        restore()
    else:
        fail(f"Unknown action: {action}")


if __name__ == "__main__":
    main()
