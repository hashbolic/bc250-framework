#!/usr/bin/env python3
from __future__ import annotations

import difflib
import html
import os
import re
import shutil
import sqlite3
import stat
import sys
import tempfile
import unicodedata
from dataclasses import dataclass
from pathlib import Path

if len(sys.argv) != 5:
    raise SystemExit("usage: optiscaler_lutris_selective.py HOME RUNNER WIKI BACKUP")

home = Path(sys.argv[1]).resolve()
runner_name = sys.argv[2]
wiki_page = Path(sys.argv[3]).resolve()
backup_root = Path(sys.argv[4]).resolve()

TOP_RUNNER = re.compile(r"^runner\s*:\s*(.*?)\s*(?:#.*)?$")
TOP_WINE = re.compile(r"^wine\s*:\s*(?:#.*)?$")
TOP_NAME = re.compile(r"^(?:name|game_name)\s*:\s*(.*?)\s*(?:#.*)?$")
VERSION = re.compile(r"^(?P<indent>[ \t]+)version\s*:\s*(?P<value>.*?)(?P<ending>\r?\n)?$")
SYSTEM_BLOCK = re.compile(r"^system\s*:\s*(?:#.*)?$")
ENV_BLOCK = re.compile(r"^(?P<indent>[ \t]+)env\s*:\s*(?:#.*)?$")
FSR4_ENV = {
    "PROTON_FSR4_UPGRADE": "4.1.1",
    "PROTON_USE_OPTISCALER": "1",
}
MD_LINK = re.compile(r"!\[[^\]]*\]\([^)]+\)|\[([^\]]+)\]\([^)]+\)")
TAG = re.compile(r"<[^>]+>")
YEAR = re.compile(r"\s*\((?:19|20)\d{2}\)\s*$")
WORK_MARKERS = ("✅", "💥", "✔️", "✔", ":white_check_mark:", ":heavy_check_mark:", ":collision:")
FAIL_MARKERS = ("❌", "💀", ":x:", ":skull:")
LINUX_MARKERS = ("🐧", ":penguin:")


def dequote(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
        return value[1:-1]
    return value


def clean_markdown(value: str) -> str:
    def repl(match: re.Match[str]) -> str:
        return match.group(1) or ""
    value = MD_LINK.sub(repl, value)
    value = TAG.sub("", value)
    value = value.replace("**", "").replace("__", "").replace(chr(96), "")
    return html.unescape(value).strip()


def normalize_title(value: str) -> str:
    value = clean_markdown(value)
    value = value.replace("™", "").replace("®", "").replace("©", "")
    value = YEAR.sub("", value)
    value = unicodedata.normalize("NFKD", value)
    value = "".join(ch for ch in value if not unicodedata.combining(ch))
    value = value.casefold().replace("&", " and ")
    value = re.sub(r"[^a-z0-9]+", " ", value)
    return " ".join(value.split())


_STORE_SUFFIXES = {
    "gog", "steam", "epic", "egs", "heroic",
    "installer", "setup", "launcher",
}
_EDITION_SUFFIXES = (
    ("ultimate", "edition"),
    ("complete", "edition"),
    ("deluxe", "edition"),
    ("standard", "edition"),
    ("game", "of", "the", "year"),
    ("goty",),
)


def canonical_title(value: str) -> str:
    """Normalize Lutris/store naming without broad fuzzy matching.

    Lutris entries created from installers often append store or edition words
    (for example "Cyberpunk 2077 Installer" or "Cyberpunk 2077 GOG"), while
    OptiScaler keeps the canonical game title. Strip only known suffixes.
    """
    tokens = normalize_title(value).split()
    changed = True
    while tokens and changed:
        changed = False
        if tokens and tokens[-1] in _STORE_SUFFIXES:
            tokens.pop()
            changed = True
            continue
        for suffix in _EDITION_SUFFIXES:
            n = len(suffix)
            if len(tokens) >= n and tuple(tokens[-n:]) == suffix:
                del tokens[-n:]
                changed = True
                break
    return " ".join(tokens)


@dataclass
class Compat:
    title: str
    working: bool
    linux: bool
    risky: bool
    notes: str


def _has_any(value: str, markers: tuple[str, ...]) -> bool:
    folded = value.casefold()
    return any(marker.casefold() in folded for marker in markers)


def _compat_from_cells(cells: list[str], *, linux: bool = False) -> Compat | None:
    if len(cells) < 3:
        return None
    title = clean_markdown(cells[0])
    if not title or title.casefold() == "game":
        return None
    status = cells[1]
    if not (_has_any(status, WORK_MARKERS) or _has_any(status, FAIL_MARKERS)):
        return None
    notes = clean_markdown(cells[4]) if len(cells) > 4 else ""
    inputs = clean_markdown(cells[2]) if len(cells) > 2 else ""
    working = _has_any(status, WORK_MARKERS) and not _has_any(status, FAIL_MARKERS)
    linux = linux or _has_any(" ".join(cells), LINUX_MARKERS) or "linux" in notes.casefold()
    text = f"{inputs} {notes}".casefold()
    risky = any(token in text for token in (
        "anti-cheat", "anticheat", "eac active", "eac bypass",
        "use at your own risk",
    ))
    if re.search(r"fsr4.{0,80}(?:doesn.t work|does not work|not working|crash|broken|severe)", text):
        risky = True
    return Compat(title, working, linux, risky, notes)


WIKI_SOURCE_LINES = wiki_page.read_text(encoding="utf-8", errors="replace").splitlines()


def parse_wiki_lines(lines: list[str]) -> list[Compat]:
    entries: list[Compat] = []
    last: Compat | None = None
    for raw in lines:
        line = raw.strip()
        if not line:
            continue
        if _has_any(line, LINUX_MARKERS) and last is not None and "|" not in line:
            last.linux = True
            continue
        if "|" not in line:
            continue
        cells = [cell.strip() for cell in line.strip("|").split("|")]
        item = _compat_from_cells(cells)
        if item is None:
            continue
        entries.append(item)
        last = item
    return entries


def raw_title_fallback(name: str) -> Compat | None:
    """Find an exact title row directly in the wiki source.

    This protects against upstream using a different checkmark shortcode or
    formatting style on an individual row. It remains conservative: the game
    title itself must match exactly after our normal store/edition cleanup.
    """
    wanted = canonical_title(name)
    if not wanted:
        return None
    for index, raw in enumerate(WIKI_SOURCE_LINES):
        line = raw.strip()
        if "|" not in line:
            continue
        cells = [cell.strip() for cell in line.strip("|").split("|")]
        if not cells:
            continue
        title = clean_markdown(cells[0])
        if canonical_title(title) != wanted:
            continue

        linux = _has_any(line, LINUX_MARKERS)
        for follow in WIKI_SOURCE_LINES[index + 1:index + 4]:
            follow_line = follow.strip()
            if "|" in follow_line and (_has_any(follow_line, WORK_MARKERS) or _has_any(follow_line, FAIL_MARKERS)):
                break
            if _has_any(follow_line, LINUX_MARKERS):
                linux = True

        item = _compat_from_cells(cells, linux=linux)
        if item is not None:
            return item

        # If the title row is exact but its status uses a future upstream
        # spelling, refuse to guess rather than enabling FSR4 unsafely.
        return None
    return None


compat = parse_wiki_lines(WIKI_SOURCE_LINES)
if len(compat) < 100:
    raise SystemExit(f"ERROR: parsed only {len(compat)} compatibility entries; upstream format may have changed")

by_norm = {normalize_title(item.title): item for item in compat}
by_canonical = {canonical_title(item.title): item for item in compat}


def best_match(name: str) -> Compat | None:
    key = normalize_title(name)
    if not key:
        return None
    exact = by_norm.get(key)
    if exact:
        return exact

    canonical = canonical_title(name)
    if canonical:
        exact = by_canonical.get(canonical)
        if exact:
            return exact

    source_exact = raw_title_fallback(name)
    if source_exact is not None:
        return source_exact

    # Conservative fuzzy fallback. Prefer canonical names so benign store /
    # edition suffixes do not lower the similarity score.
    probe = canonical or key
    hits = []
    for other, item in by_canonical.items():
        ratio = difflib.SequenceMatcher(None, probe, other).ratio()
        if ratio >= 0.92:
            hits.append((ratio, item))
    hits.sort(key=lambda pair: pair[0], reverse=True)
    if not hits:
        return None
    if len(hits) > 1 and hits[0][0] - hits[1][0] < 0.025:
        return None
    return hits[0][1]


def top_value(lines: list[str], regex: re.Pattern[str]) -> str | None:
    for line in lines:
        if line.startswith((" ", "\t")):
            continue
        match = regex.match(line.rstrip("\r\n"))
        if match:
            return dequote(match.group(1))
    return None


def line_indent(line: str) -> int | None:
    body = line.rstrip("\r\n")
    if not body.strip() or body.lstrip().startswith("#"):
        return None
    return len(body) - len(body.lstrip(" "))


def wine_version(text: str) -> str | None:
    lines = text.splitlines(keepends=True)
    wine_idx = next((i for i, line in enumerate(lines)
                     if not line.startswith((" ", "\t"))
                     and TOP_WINE.match(line.rstrip("\r\n"))), None)
    if wine_idx is None:
        return None
    end = len(lines)
    for i in range(wine_idx + 1, len(lines)):
        if line_indent(lines[i]) == 0:
            end = i
            break
    for line in lines[wine_idx + 1:end]:
        match = VERSION.match(line)
        if match:
            return dequote(match.group("value").split("#", 1)[0].strip())
    return None


def set_wine_version(text: str) -> tuple[str, bool]:
    lines = text.splitlines(keepends=True)
    wine_idx = next((i for i, line in enumerate(lines)
                     if not line.startswith((" ", "\t"))
                     and TOP_WINE.match(line.rstrip("\r\n"))), None)
    if wine_idx is None:
        suffix = "" if not text or text.endswith("\n") else "\n"
        return text + suffix + f"wine:\n  version: {runner_name}\n", True
    end = len(lines)
    for i in range(wine_idx + 1, len(lines)):
        if line_indent(lines[i]) == 0:
            end = i
            break
    for i in range(wine_idx + 1, end):
        match = VERSION.match(lines[i])
        if not match:
            continue
        current = dequote(match.group("value").split("#", 1)[0].strip())
        if current == runner_name:
            return text, False
        newline = "\r\n" if lines[i].endswith("\r\n") else "\n"
        lines[i] = f"{match.group('indent')}version: {runner_name}{newline}"
        return "".join(lines), True
    lines.insert(wine_idx + 1, f"  version: {runner_name}\n")
    return "".join(lines), True


def fsr4_env_values(text: str) -> dict[str, str]:
    """Read only Lutris' standard top-level system.env mapping."""
    lines = text.splitlines(keepends=True)
    system_idx = next(
        (i for i, line in enumerate(lines)
         if not line.startswith((" ", "\t")) and SYSTEM_BLOCK.match(line.rstrip("\r\n"))),
        None,
    )
    if system_idx is None:
        return {}

    system_end = len(lines)
    for i in range(system_idx + 1, len(lines)):
        indent = line_indent(lines[i])
        if indent == 0:
            system_end = i
            break

    env_idx = None
    env_indent = None
    for i in range(system_idx + 1, system_end):
        match = ENV_BLOCK.match(lines[i].rstrip("\r\n"))
        if match:
            env_idx = i
            env_indent = len(match.group("indent"))
            break
    if env_idx is None or env_indent is None:
        return {}

    env_end = system_end
    for i in range(env_idx + 1, system_end):
        indent = line_indent(lines[i])
        if indent is not None and indent <= env_indent:
            env_end = i
            break

    result: dict[str, str] = {}
    for line in lines[env_idx + 1:env_end]:
        body = line.rstrip("\r\n")
        indent = len(body) - len(body.lstrip(" "))
        if indent <= env_indent or ":" not in body:
            continue
        key, value = body.strip().split(":", 1)
        key = dequote(key.strip())
        if key in FSR4_ENV:
            result[key] = dequote(value.split("#", 1)[0].strip())
    return result


def set_fsr4_env(text: str) -> tuple[str, bool]:
    """Ensure the verified game gets explicit FSR4/OptiScaler Lutris ENV."""
    lines = text.splitlines(keepends=True)
    system_idx = next(
        (i for i, line in enumerate(lines)
         if not line.startswith((" ", "\t")) and SYSTEM_BLOCK.match(line.rstrip("\r\n"))),
        None,
    )

    # A non-standard inline top-level system mapping is not safe to rewrite
    # without a YAML parser. Refuse it rather than risk damaging the game file.
    if system_idx is None:
        inline_system = any(
            not line.startswith((" ", "\t")) and line.lstrip().startswith("system:")
            for line in lines
        )
        if inline_system:
            raise ValueError("unsupported inline Lutris system mapping")
        suffix = "" if not text or text.endswith("\n") else "\n"
        block = "system:\n  env:\n" + "".join(
            f"    {key}: '{value}'\n" for key, value in FSR4_ENV.items()
        )
        return text + suffix + block, True

    system_end = len(lines)
    for i in range(system_idx + 1, len(lines)):
        indent = line_indent(lines[i])
        if indent == 0:
            system_end = i
            break

    env_idx = None
    env_indent = None
    for i in range(system_idx + 1, system_end):
        match = ENV_BLOCK.match(lines[i].rstrip("\r\n"))
        if match:
            env_idx = i
            env_indent = len(match.group("indent"))
            break

    if env_idx is None:
        # Standard Lutris top-level maps use two spaces below system.
        insert = [
            "  env:\n",
            *[f"    {key}: '{value}'\n" for key, value in FSR4_ENV.items()],
        ]
        lines[system_idx + 1:system_idx + 1] = insert
        return "".join(lines), True

    assert env_indent is not None
    env_end = system_end
    for i in range(env_idx + 1, system_end):
        indent = line_indent(lines[i])
        if indent is not None and indent <= env_indent:
            env_end = i
            break

    found: set[str] = set()
    changed = False
    entry_indent = " " * (env_indent + 2)
    for i in range(env_idx + 1, env_end):
        body = lines[i].rstrip("\r\n")
        stripped = body.strip()
        if ":" not in stripped:
            continue
        key, raw_value = stripped.split(":", 1)
        key = dequote(key.strip())
        if key not in FSR4_ENV:
            continue
        found.add(key)
        wanted = FSR4_ENV[key]
        current = dequote(raw_value.split("#", 1)[0].strip())
        if current == wanted:
            continue
        indent = body[:len(body) - len(body.lstrip(" "))]
        newline = "\r\n" if lines[i].endswith("\r\n") else "\n"
        lines[i] = f"{indent}{key}: '{wanted}'{newline}"
        changed = True

    missing = [key for key in FSR4_ENV if key not in found]
    if missing:
        lines[env_idx + 1:env_idx + 1] = [
            f"{entry_indent}{key}: '{FSR4_ENV[key]}'\n" for key in missing
        ]
        changed = True

    return "".join(lines), changed


db_games: dict[str, dict[str, str]] = {}
for db_path in (home / ".local/share/lutris/pga.db",
                home / ".var/app/net.lutris.Lutris/data/lutris/pga.db"):
    if not db_path.is_file():
        continue
    try:
        con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
        con.row_factory = sqlite3.Row
        columns = {row[1] for row in con.execute("PRAGMA table_info(games)")}
        fields = [field for field in ("name", "slug", "configpath", "runner") if field in columns]
        if "name" not in fields:
            con.close()
            continue
        for row in con.execute("SELECT " + ",".join(fields) + " FROM games"):
            record = {
                "name": str(row["name"] or "").strip() if "name" in fields else "",
                "slug": str(row["slug"] or "").strip() if "slug" in fields else "",
                "configpath": str(row["configpath"] or "").strip() if "configpath" in fields else "",
                "runner": str(row["runner"] or "").strip() if "runner" in fields else "",
            }
            for raw_key in (record["configpath"], record["slug"]):
                if not raw_key:
                    continue
                db_games[raw_key.casefold()] = record
                db_games[normalize_title(raw_key)] = record
        con.close()
    except sqlite3.Error:
        pass


def game_record(path: Path) -> dict[str, str]:
    stem = path.stem
    candidates = (
        stem.casefold(),
        normalize_title(stem),
        normalize_title(re.sub(r"-\d+$", "", stem)),
    )
    for key in candidates:
        record = db_games.get(key)
        if record:
            return record
    return {}


def game_name(path: Path, text: str) -> str:
    record = game_record(path)
    if record.get("name"):
        return record["name"]
    lines = text.splitlines(keepends=True)
    explicit = top_value(lines, TOP_NAME)
    if explicit:
        return explicit
    return re.sub(r"-\d+$", "", path.stem).replace("-", " ")


def game_runner(path: Path, text: str) -> str:
    # Lutris stores the runner in pga.db. The per-game YAML normally contains
    # runner-specific settings but no top-level "runner:" key. Prefer the DB,
    # which is the same source Lutris Game.__init__ uses for runner_name.
    record = game_record(path)
    runner = str(record.get("runner") or "").strip()
    if runner:
        return runner

    # Compatibility fallback for hand-written/legacy configs.
    lines = text.splitlines(keepends=True)
    yaml_runner = top_value(lines, TOP_RUNNER)
    if yaml_runner:
        return yaml_runner
    if any(
        not line.startswith((" ", "\t")) and TOP_WINE.match(line.rstrip("\r\n"))
        for line in lines
    ):
        return "wine"
    return "<unknown>"


roots = [
    home / ".config/lutris/games",
    home / ".local/share/lutris/games",
    home / ".var/app/net.lutris.Lutris/config/lutris/games",
]
files: list[Path] = []
for root in roots:
    if not root.is_dir():
        continue
    for pattern in ("*.yml", "*.yaml"):
        for path in sorted(root.glob(pattern)):
            if path.is_file() and not path.is_symlink() and path not in files:
                files.append(path)

changed = []
already = []
general = []
risky = []
unmatched = []
non_wine = []
errors = []

for path in files:
    try:
        raw = path.read_text(encoding="utf-8", errors="surrogateescape")
        runner = game_runner(path, raw)
        name = game_name(path, raw)
        if runner != "wine":
            non_wine.append((name, runner))
            continue
        item = best_match(name)
        if item is None:
            unmatched.append(name)
            continue
        if not item.working or item.risky:
            risky.append((name, item))
            continue
        if not item.linux:
            general.append((name, item))
            continue
        updated, runner_changed = set_wine_version(raw)
        updated, env_changed = set_fsr4_env(updated)
        did_change = runner_changed or env_changed
        if not did_change:
            already.append((name, path, item))
            continue
        rel = path.relative_to(home) if path.is_relative_to(home) else Path(path.name)
        backup = backup_root / rel
        backup.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, backup)
        mode = stat.S_IMODE(path.stat().st_mode)
        fd, temp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
        temp = Path(temp_name)
        try:
            with os.fdopen(fd, "w", encoding="utf-8", errors="surrogateescape", newline="") as handle:
                handle.write(updated)
                handle.flush()
                os.fsync(handle.fileno())
            os.chmod(temp, mode)
            os.replace(temp, path)
        finally:
            if temp.exists():
                temp.unlink()
        changed.append((name, path, item))
    except Exception as exc:
        errors.append((path, str(exc)))

safe_linux = sum(1 for item in compat if item.working and item.linux and not item.risky)
print(f"OptiScaler entries: {len(compat)}; safe Linux-confirmed: {safe_linux}")
print(f"Lutris configs: {len(files)}")
print(f"Switched: {len(changed)}; already BC250: {len(already)}")
print(f"Working but no Linux proof: {len(general)}; risky/not-working: {len(risky)}")
print(f"Unmatched: {len(unmatched)}; non-Wine: {len(non_wine)}; errors: {len(errors)}")
print(f"Lutris DB records indexed: {len(db_games)}")

for name, _path, item in changed:
    print(f"  ✅ switch: {name} -> {runner_name} [OptiScaler: {item.title}]")
for name, _path, item in already:
    print(f"  = already: {name} [runner + FSR4 ENV ready; OptiScaler: {item.title}]")
for name, _item in general:
    print(f"  ? keep: {name} [works generally; no explicit Linux evidence]")
for name, item in risky:
    note = item.notes[:100] + ("..." if len(item.notes) > 100 else "")
    print(f"  ⚠ keep: {name} [{note or 'risk/not-working marker'}]")
for name in unmatched:
    norm = normalize_title(name)
    canon = canonical_title(name)
    nearby = sorted(
        (
            (difflib.SequenceMatcher(None, canon or norm, key).ratio(), item.title)
            for key, item in by_canonical.items()
        ),
        reverse=True,
    )[:3]
    hint = ", ".join(f"{title} ({score:.2f})" for score, title in nearby)
    print(f"  - keep: {name} [not safely matched; normalized={norm!r}; canonical={canon!r}]")
    if hint:
        print(f"      nearest: {hint}")

if errors:
    for path, error in errors:
        print(f"ERROR {path}: {error}", file=sys.stderr)
    raise SystemExit(20)

for _name, path, _item in changed + already:
    text = path.read_text(encoding="utf-8", errors="surrogateescape")
    if wine_version(text) != runner_name:
        raise SystemExit(f"ERROR: runner read-back failed for {path}")
    env = fsr4_env_values(text)
    for key, wanted in FSR4_ENV.items():
        if env.get(key) != wanted:
            raise SystemExit(
                f"ERROR: ENV read-back failed for {path}: "
                f"{key}={env.get(key)!r}, expected {wanted!r}"
            )

print("Selective read-back verification: OK")
print("Explicit ENV: PROTON_FSR4_UPGRADE=4.1.1, PROTON_USE_OPTISCALER=1")
