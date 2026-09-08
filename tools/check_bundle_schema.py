#!/usr/bin/env python3
"""Validate the Databricks Asset Bundle without a workspace.

`databricks bundle validate` authenticates before it resolves anything, so it
cannot run in a pipeline that holds no credentials — and no pipeline in this
repository does. That leaves a real gap: a typo in a field name would not be
caught until someone deployed by hand.

This closes the gap. It checks two things offline:

  1. Every bundle YAML file parses.
  2. Every key used exists in the Databricks CLI's own JSON schema, which
     `databricks bundle schema` emits and which therefore tracks the CLI
     version actually installed rather than a list copied from the docs.

What it deliberately does NOT check is whether values are correct — that a
node type exists in the region, that a schedule is valid, that a notebook path
resolves. Those need a workspace. This is a spell-checker, not a deployment.
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
BUNDLE_DIR = REPO / "data" / "databricks"
SCHEMA_CACHE = Path("/tmp/dab-schema.json")  # noqa: S108

RED = "\033[0;31m"
GREEN = "\033[0;32m"
NC = "\033[0m"


def load_yaml(path: Path) -> dict:
    """Parse YAML using PyYAML, falling back to Ruby's bundled parser.

    The fallback exists so this runs on a clean machine. Ruby ships with macOS
    and with the GitHub Actions Ubuntu images; PyYAML is not guaranteed on
    either.
    """
    try:
        import yaml  # noqa: PLC0415

        return yaml.safe_load(path.read_text()) or {}
    except ImportError:
        pass

    try:
        out = subprocess.run(  # noqa: S603
            ["ruby", "-ryaml", "-rjson", "-e", f"puts YAML.load_file({str(path)!r}).to_json"],  # noqa: S607
            capture_output=True,
            text=True,
            check=True,
        )
        return json.loads(out.stdout)
    except (FileNotFoundError, subprocess.CalledProcessError) as exc:
        sys.exit(f"{RED}FAIL{NC} cannot parse YAML: install PyYAML (pip install pyyaml) — {exc}")


def load_schema() -> dict:
    if SCHEMA_CACHE.exists():
        return json.loads(SCHEMA_CACHE.read_text())
    try:
        out = subprocess.run(  # noqa: S603
            ["databricks", "bundle", "schema"],  # noqa: S607
            capture_output=True,
            text=True,
            check=True,
        )
    except (FileNotFoundError, subprocess.CalledProcessError) as exc:
        sys.exit(f"{RED}FAIL{NC} could not run `databricks bundle schema` — {exc}")
    return json.loads(out.stdout)


class Schema:
    """Minimal resolver for the CLI's schema.

    Two shapes need handling. References are Go type paths
    (`#/$defs/github.com/databricks/cli/...`), and almost every node is wrapped
    in a `oneOf` whose second branch is the `${var.x}` string form — because
    any field may be a variable reference rather than a literal.
    """

    def __init__(self, root: dict) -> None:
        self.root = root

    def deref(self, node: object, depth: int = 0) -> dict:
        while isinstance(node, dict) and "$ref" in node and depth < 25:
            cur: object = self.root
            for part in (p for p in node["$ref"].split("/") if p not in ("#", "")):
                if not isinstance(cur, dict) or part not in cur:
                    return {}
                cur = cur[part]
            node = cur
            depth += 1
        return node if isinstance(node, dict) else {}

    def branches(self, node: object):
        node = self.deref(node)
        yield node
        for key in ("oneOf", "anyOf", "allOf"):
            for sub in node.get(key) or []:
                yield from self.branches(sub)

    def props(self, node: object) -> dict:
        found: dict = {}
        for branch in self.branches(node):
            found.update(branch.get("properties") or {})
        return found

    def map_value(self, node: object) -> dict:
        for branch in self.branches(node):
            extra = branch.get("additionalProperties")
            if isinstance(extra, dict):
                return self.deref(extra)
        return {}

    def items(self, node: object) -> dict:
        for branch in self.branches(node):
            item = branch.get("items")
            if isinstance(item, dict):
                return self.deref(item)
        return {}


def walk(schema: Schema, node: dict, data: object, path: str, errors: list[str]) -> None:
    """Recursively confirm every key in `data` exists in the schema node."""
    if isinstance(data, dict):
        allowed = schema.props(node)
        # A node with no declared properties is a free-form map (tags,
        # spark_conf, base_parameters): its keys are user-chosen by design.
        if not allowed:
            return
        for key, value in data.items():
            if key not in allowed:
                errors.append(f"{path}.{key}")
                continue
            walk(schema, allowed[key], value, f"{path}.{key}", errors)
    elif isinstance(data, list):
        item = schema.items(node)
        for index, value in enumerate(data):
            walk(schema, item, value, f"{path}[{index}]", errors)


def main() -> int:
    schema = Schema(load_schema())
    root = schema.root
    errors: list[str] = []
    files = sorted(BUNDLE_DIR.rglob("databricks.yml")) + sorted(
        (BUNDLE_DIR / "resources").glob("*.yml")
    )
    if not files:
        sys.exit(f"{RED}FAIL{NC} no bundle files found under {BUNDLE_DIR}")

    for path in files:
        data = load_yaml(path)
        rel = path.relative_to(REPO)
        print(f"==> {rel}")
        for top, value in data.items():
            node = schema.props(root).get(top)
            if node is None:
                errors.append(f"{rel}:{top}")
                continue
            # `targets` and `resources.jobs` are maps keyed by a name the
            # author chooses, so descend through the map's value type.
            if top == "targets":
                for name, target in (value or {}).items():
                    walk(schema, schema.map_value(node), target, f"{rel}:targets.{name}", errors)
            elif top == "resources":
                for kind, group in (value or {}).items():
                    kind_node = schema.props(node).get(kind)
                    if kind_node is None:
                        errors.append(f"{rel}:resources.{kind}")
                        continue
                    for name, resource in (group or {}).items():
                        walk(
                            schema,
                            schema.map_value(kind_node),
                            resource,
                            f"{rel}:resources.{kind}.{name}",
                            errors,
                        )
            else:
                walk(schema, node, value, f"{rel}:{top}", errors)

    if errors:
        for err in errors:
            print(f"{RED}FAIL{NC} unknown key: {err}")
        return 1
    print(f"{GREEN}PASS{NC} bundle parses and every key exists in the Databricks CLI schema")
    return 0


if __name__ == "__main__":
    sys.exit(main())
