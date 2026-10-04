#!/usr/bin/env python3
"""Minimal, dependency-free Steam localconfig.vdf LaunchOptions editor."""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import stat
import tempfile
from pathlib import Path

APPID = "730"


def matching_brace(text: str, opening: int) -> int:
    depth = 0
    quoted = False
    escaped = False
    for index in range(opening, len(text)):
        ch = text[index]
        if quoted:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                quoted = False
            continue
        if ch == '"':
            quoted = True
        elif ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return index
    raise ValueError("unbalanced VDF braces")


def named_block(text: str, key: str, start: int = 0, end: int | None = None):
    end = len(text) if end is None else end
    pattern = re.compile(
        rf'(?mi)^[ \t]*"{re.escape(key)}"[ \t]*(?:\r?\n[ \t]*)?\{{'
    )
    match = pattern.search(text, start, end)
    if not match:
        return None
    opening = text.find("{", match.start(), match.end())
    closing = matching_brace(text, opening)
    if closing > end:
        return None
    return match.start(), opening, closing


def app_block(text: str, appid: str):
    root = named_block(text, "UserLocalConfigStore")
    if not root:
        raise ValueError("UserLocalConfigStore block not found")
    software = named_block(text, "Software", root[1] + 1, root[2])
    valve = named_block(text, "Valve", software[1] + 1, software[2]) if software else None
    steam = named_block(text, "Steam", valve[1] + 1, valve[2]) if valve else None
    apps = named_block(text, "apps", steam[1] + 1, steam[2]) if steam else None
    if not apps:
        raise ValueError("Steam apps block not found")
    app = named_block(text, appid, apps[1] + 1, apps[2])
    return app


def get_launch_options(text: str, appid: str) -> str | None:
    block = app_block(text, appid)
    if not block:
        return None
    body = text[block[1] + 1:block[2]]
    match = re.search(r'(?mi)^[ \t]*"LaunchOptions"[ \t]+"((?:\\.|[^"])*)"[ \t]*$', body)
    if not match:
        return ""
    value = match.group(1)
    return value.replace(r'\"', '"').replace(r"\\", "\\")


def escaped(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', r'\"')


def set_launch_options(text: str, appid: str, value: str) -> str:
    block = app_block(text, appid)
    if not block:
        raise ValueError(f"Steam app {appid} is not present in localconfig.vdf")
    body_start, body_end = block[1] + 1, block[2]
    body = text[body_start:body_end]
    pattern = re.compile(r'(?mi)^([ \t]*)"LaunchOptions"[ \t]+"(?:\\.|[^"])*"[ \t]*(\r?\n)?')
    match = pattern.search(body)
    if match:
        if value:
            newline = match.group(2) or "\n"
            replacement = f'{match.group(1)}"LaunchOptions"\t\t"{escaped(value)}"{newline}'
        else:
            replacement = ""
        body = body[:match.start()] + replacement + body[match.end():]
        return text[:body_start] + body + text[body_end:]

    if not value:
        return text
    key_line_start = text.rfind("\n", block[0], block[1]) + 1
    key_indent = re.match(r"[ \t]*", text[key_line_start:block[0]]).group(0)
    child_indent = key_indent + "\t"
    insertion = f'\n{child_indent}"LaunchOptions"\t\t"{escaped(value)}"'
    return text[:body_end] + insertion + text[body_end:]


def configs(home: Path):
    roots = (
        home / ".local/share/Steam",
        home / ".steam/steam",
        home / ".steam/root",
    )
    seen = set()
    for root in roots:
        try:
            real = root.resolve()
        except OSError:
            continue
        if real in seen or not real.is_dir():
            continue
        seen.add(real)
        for path in sorted((real / "userdata").glob("*/config/localconfig.vdf")):
            if path.is_file():
                yield path


def atomic_write(path: Path, content: str):
    mode = stat.S_IMODE(path.stat().st_mode)
    fd, tmp_name = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    tmp = Path(tmp_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    finally:
        try:
            tmp.unlink()
        except FileNotFoundError:
            pass


def state_path(home: Path) -> Path:
    return home / ".local/share/bc250-framework/games/cs2.json"


def load_state(home: Path) -> dict:
    p = state_path(home)
    if not p.is_file():
        return {"files": {}}
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except Exception:
        return {"files": {}}


def save_state(home: Path, data: dict):
    p = state_path(home)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def cmd_status(home: Path):
    found = False
    for path in configs(home):
        try:
            current = get_launch_options(path.read_text(encoding="utf-8"), APPID)
        except (OSError, UnicodeError, ValueError):
            continue
        if current is None:
            continue
        found = True
        print(f"{path}: {current or '(empty)'}")
    return 0 if found else 2


def cmd_apply(home: Path, launch: str):
    state = load_state(home)
    state.setdefault("files", {})
    changed = 0
    for path in configs(home):
        try:
            text = path.read_text(encoding="utf-8")
            current = get_launch_options(text, APPID)
        except (OSError, UnicodeError, ValueError):
            continue
        if current is None:
            continue
        key = str(path)
        if key not in state["files"]:
            state["files"][key] = {"original": current}
        if current == launch:
            print(f"[OK] {path}: already applied")
            continue
        backup = path.with_name(path.name + ".bc250-backup")
        if not backup.exists():
            shutil.copy2(path, backup)
        atomic_write(path, set_launch_options(text, APPID, launch))
        print(f"[OK] {path}: applied")
        changed += 1
    if not state["files"]:
        raise SystemExit("CS2 AppID 730 was not found in any Steam localconfig.vdf")
    state["profile"] = launch
    save_state(home, state)
    return changed


def cmd_reset(home: Path):
    state = load_state(home)
    files = state.get("files") or {}
    if not files:
        raise SystemExit("No BC250 CS2 profile state is recorded")
    restored = 0
    for raw, record in files.items():
        path = Path(raw)
        if not path.is_file():
            continue
        text = path.read_text(encoding="utf-8")
        if app_block(text, APPID) is None:
            continue
        original = str((record or {}).get("original") or "")
        atomic_write(path, set_launch_options(text, APPID, original))
        print(f"[OK] {path}: restored original LaunchOptions")
        restored += 1
    try:
        state_path(home).unlink()
    except FileNotFoundError:
        pass
    return restored


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--home", required=True)
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("status")
    apply = sub.add_parser("apply")
    apply.add_argument("--launch", required=True)
    sub.add_parser("reset")
    args = parser.parse_args()
    home = Path(args.home)
    if args.cmd == "status":
        raise SystemExit(cmd_status(home))
    if args.cmd == "apply":
        cmd_apply(home, args.launch)
        return
    if args.cmd == "reset":
        cmd_reset(home)
        return


if __name__ == "__main__":
    main()
