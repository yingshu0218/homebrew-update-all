#!/usr/bin/env python3
"""Select and compare valid v-prefixed SemVer release tags."""

from __future__ import annotations

import re
import sys


TAG_PATTERN = re.compile(
    r"^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
    r"(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?"
    r"(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$"
)


def parse_tag(tag: str):
    match = TAG_PATTERN.fullmatch(tag)
    if not match:
        raise ValueError(f"invalid SemVer release tag: {tag}")
    major, minor, patch, prerelease, _build = match.groups()
    prerelease_ids = prerelease.split(".") if prerelease is not None else None
    if prerelease_ids:
        for identifier in prerelease_ids:
            if identifier.isdigit() and len(identifier) > 1 and identifier.startswith("0"):
                raise ValueError(f"invalid numeric prerelease identifier in {tag}")
    return (int(major), int(minor), int(patch), prerelease_ids)


def compare_tags(left: str, right: str) -> int:
    left_version = parse_tag(left)
    right_version = parse_tag(right)
    left_core, left_pre = left_version[:3], left_version[3]
    right_core, right_pre = right_version[:3], right_version[3]
    if left_core != right_core:
        return (left_core > right_core) - (left_core < right_core)
    if left_pre is None or right_pre is None:
        if left_pre is right_pre:
            return 0
        return 1 if left_pre is None else -1
    for left_id, right_id in zip(left_pre, right_pre):
        if left_id == right_id:
            continue
        left_numeric, right_numeric = left_id.isdigit(), right_id.isdigit()
        if left_numeric and right_numeric:
            return (int(left_id) > int(right_id)) - (int(left_id) < int(right_id))
        if left_numeric != right_numeric:
            return -1 if left_numeric else 1
        return (left_id > right_id) - (left_id < right_id)
    return (len(left_pre) > len(right_pre)) - (len(left_pre) < len(right_pre))


def main(argv: list[str]) -> int:
    if len(argv) == 2 and argv[1] == "select":
        tags = []
        for raw in sys.stdin:
            tag = raw.strip()
            if not tag:
                continue
            try:
                parse_tag(tag)
            except ValueError:
                continue
            tags.append(tag)
        if tags:
            # SemVer precedence ignores build metadata; lexical tie-break makes
            # selection deterministic when multiple refs have equal precedence.
            selected = max(tags, key=lambda tag: (parse_tag(tag)[:3], prerelease_key(tag), tag))
            print(selected)
        return 0

    if len(argv) == 4 and argv[1] == "compare":
        print(compare_tags(argv[2], argv[3]))
        return 0

    if len(argv) == 4 and argv[1] == "require-not-older":
        result = compare_tags(argv[2], argv[3])
        if result < 0:
            print(f"refusing Formula downgrade: {argv[2]} is older than {argv[3]}", file=sys.stderr)
            return 1
        return 0

    print(
        "usage: release-tags.py select < tags.txt | compare <left> <right> | "
        "require-not-older <candidate> <current>",
        file=sys.stderr,
    )
    return 2


def prerelease_key(tag: str):
    prerelease = parse_tag(tag)[3]
    if prerelease is None:
        return (1, ())
    parts = []
    for identifier in prerelease:
        if identifier.isdigit():
            parts.append((0, int(identifier)))
        else:
            parts.append((1, identifier))
    return (0, tuple(parts))


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv))
    except ValueError as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(2)
