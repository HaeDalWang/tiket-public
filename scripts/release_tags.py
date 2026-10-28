#!/usr/bin/env python3
"""정식 릴리스 태그(`vX.Y.Z`)를 숫자 순으로 비교한다.

문자열로 정렬하면 v1.9.0 이 v1.10.0 을 이긴다. `-rc1` 같은 예비 태그와
`alpha-…` 같은 다른 형식은 정식 릴리스가 아니므로 고르지 않는다.

    git ls-remote --tags <url> | python3 scripts/release_tags.py latest

가장 높은 정식 태그를 한 줄 출력한다. 없으면 아무것도 출력하지 않고 exit 1.
온보딩(외부 스킬)과 워크스페이스 자동 업데이트가 같이 쓴다.
"""

from __future__ import annotations

import re
import sys

RELEASE_TAG = re.compile(r"^v(\d+)\.(\d+)\.(\d+)$")


def version(tag: str) -> tuple[int, int, int] | None:
    match = RELEASE_TAG.match(tag)
    return tuple(int(part) for part in match.groups()) if match else None  # type: ignore[return-value]


def latest(tags: list[str]) -> str | None:
    releases = [tag for tag in tags if version(tag) is not None]
    return max(releases, key=version) if releases else None  # type: ignore[arg-type]


def is_newer(candidate: str, current: str) -> bool:
    new, old = version(candidate), version(current)
    return new is not None and old is not None and new > old


def tags_from_ls_remote(raw: str) -> list[str]:
    tags = []
    for line in raw.splitlines():
        ref = line.split("\t")[-1].strip()
        if ref.startswith("refs/tags/") and not ref.endswith("^{}"):
            tags.append(ref.removeprefix("refs/tags/"))
    return tags


def main(argv: list[str]) -> int:
    if argv[1:] != ["latest"]:
        print("usage: git ls-remote --tags <url> | release_tags.py latest", file=sys.stderr)
        return 2
    found = latest(tags_from_ls_remote(sys.stdin.read()))
    if found is None:
        return 1
    print(found)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
