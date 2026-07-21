#!/usr/bin/env python3
"""Validate this Claude Code plugin marketplace.

Checks performed:
  * every ``*.json`` file under the repo parses as JSON
  * ``.claude-plugin/marketplace.json`` has the expected top-level shape
  * each listed plugin's ``source`` directory exists and holds a
    ``.claude-plugin/plugin.json``
  * marketplace entry and plugin.json agree on ``name`` and ``version``
  * every ``skills/*/SKILL.md`` carries YAML frontmatter with non-empty
    ``name`` and ``description`` fields, and its ``name`` matches the
    skill's directory
  * every ``hooks/hooks.json`` parses and each command it references via
    ``${CLAUDE_PLUGIN_ROOT}/...`` points at a file that exists

Exit status is non-zero if any check fails, so it doubles as a CI gate
and a local pre-flight (``python3 scripts/validate.py``).

PyYAML is used for strict frontmatter parsing when available; without it
the script falls back to a lightweight key check and says so.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

try:
    import yaml  # type: ignore
except ImportError:  # pragma: no cover - optional dependency
    yaml = None

REPO_ROOT = Path(__file__).resolve().parent.parent
MARKETPLACE = REPO_ROOT / ".claude-plugin" / "marketplace.json"

errors: list[str] = []
warnings: list[str] = []


def err(msg: str) -> None:
    errors.append(msg)


def warn(msg: str) -> None:
    warnings.append(msg)


def rel(path: Path) -> str:
    try:
        return str(path.relative_to(REPO_ROOT))
    except ValueError:
        return str(path)


def load_json(path: Path):
    """Parse a JSON file, recording an error (and returning None) on failure."""
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        err(f"{rel(path)}: file not found")
    except json.JSONDecodeError as exc:
        err(f"{rel(path)}: invalid JSON: {exc}")
    return None


def parse_frontmatter(path: Path):
    """Return the frontmatter mapping for a Markdown file, or None on error."""
    text = path.read_text(encoding="utf-8")
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        err(f"{rel(path)}: missing opening '---' frontmatter delimiter")
        return None
    end = next((i for i in range(1, len(lines)) if lines[i].strip() == "---"), None)
    if end is None:
        err(f"{rel(path)}: missing closing '---' frontmatter delimiter")
        return None
    block = "\n".join(lines[1:end])

    if yaml is not None:
        try:
            data = yaml.safe_load(block)
        except yaml.YAMLError as exc:
            err(f"{rel(path)}: invalid YAML frontmatter: {exc}")
            return None
        if not isinstance(data, dict):
            err(f"{rel(path)}: frontmatter is not a key/value mapping")
            return None
        return data

    # Fallback: match top-level "key: value" lines only.
    data = {}
    for line in block.splitlines():
        m = re.match(r"^([A-Za-z0-9_-]+):\s?(.*)$", line)
        if m:
            data[m.group(1)] = m.group(2).strip()
    return data


def validate_all_json() -> None:
    for path in sorted(REPO_ROOT.rglob("*.json")):
        if ".git" in path.parts:
            continue
        load_json(path)


def validate_skill(skill_dir: Path) -> None:
    skill_md = skill_dir / "SKILL.md"
    if not skill_md.is_file():
        err(f"{rel(skill_dir)}: missing SKILL.md")
        return
    fm = parse_frontmatter(skill_md)
    if fm is None:
        return
    for field in ("name", "description"):
        value = fm.get(field)
        if not (isinstance(value, str) and value.strip()):
            err(f"{rel(skill_md)}: frontmatter '{field}' is missing or empty")
    name = fm.get("name")
    if isinstance(name, str) and name.strip() and name.strip() != skill_dir.name:
        err(
            f"{rel(skill_md)}: frontmatter name '{name.strip()}' "
            f"does not match directory '{skill_dir.name}'"
        )


def validate_hooks(plugin_dir: Path) -> None:
    hooks_json = plugin_dir / "hooks" / "hooks.json"
    if not hooks_json.is_file():
        return
    data = load_json(hooks_json)
    if data is None:
        return
    for event in (data.get("hooks") or {}).values():
        for group in event:
            for hook in group.get("hooks", []):
                command = hook.get("command", "")
                for ref in re.findall(r"\$\{CLAUDE_PLUGIN_ROOT\}/([^\s\"']+)", command):
                    target = plugin_dir / ref
                    if not target.exists():
                        err(f"{rel(hooks_json)}: hook command references missing file '{ref}'")


def validate_plugin(entry: dict, index: int) -> None:
    where = f"marketplace.json plugins[{index}]"
    name = entry.get("name")
    source = entry.get("source")
    version = entry.get("version")
    if not name:
        err(f"{where}: missing 'name'")
    if not source:
        err(f"{where}: missing 'source'")
        return
    if not version:
        err(f"{where} ({name}): missing 'version'")

    plugin_dir = (REPO_ROOT / source).resolve()
    if not plugin_dir.is_dir():
        err(f"{where} ({name}): source directory '{source}' does not exist")
        return

    plugin_json = plugin_dir / ".claude-plugin" / "plugin.json"
    manifest = load_json(plugin_json)
    if manifest is None:
        return

    if manifest.get("name") != name:
        err(
            f"{rel(plugin_json)}: name '{manifest.get('name')}' "
            f"disagrees with marketplace entry '{name}'"
        )
    if manifest.get("version") != version:
        err(
            f"{rel(plugin_json)}: version '{manifest.get('version')}' "
            f"disagrees with marketplace entry '{version}'"
        )

    for skill_dir in sorted((plugin_dir / "skills").glob("*/")):
        validate_skill(skill_dir)
    validate_hooks(plugin_dir)


def main() -> int:
    if yaml is None:
        warn("PyYAML not installed — frontmatter checked with a lightweight parser only")

    validate_all_json()

    market = load_json(MARKETPLACE)
    if market is None:
        # A broken marketplace manifest is fatal on its own.
        report()
        return 1

    if not market.get("name"):
        err("marketplace.json: missing top-level 'name'")
    plugins = market.get("plugins")
    if not isinstance(plugins, list) or not plugins:
        err("marketplace.json: 'plugins' must be a non-empty array")
    else:
        for i, entry in enumerate(plugins):
            validate_plugin(entry, i)

    return report()


def report() -> int:
    for w in warnings:
        print(f"warning: {w}")
    if errors:
        for e in errors:
            print(f"error: {e}")
        print(f"\nFAILED — {len(errors)} error(s)")
        return 1
    print("OK — marketplace, plugins, skills and hooks all valid")
    return 0


if __name__ == "__main__":
    sys.exit(main())
