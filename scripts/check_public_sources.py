#!/usr/bin/env python3
"""Check public URLs cited by shared Alpha documentation and examples."""

from __future__ import annotations

import argparse
import concurrent.futures
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE_DOCUMENTS = [ROOT / "agents/shared-agent-environment.md"]
SOURCE_DOCUMENTS.extend(sorted((ROOT / "examples").glob("CUST-*/tickets/*/evidence.md")))
SOURCE_LINE = re.compile(r"^\[(\d+)\]\s+(https?://\S+)\s*$", re.MULTILINE)
FACT_SOURCE_LINE = re.compile(r"^\s*- source:\s+(https?://\S+)\s*$", re.MULTILINE)


def cited_urls() -> list[tuple[Path, int, str]]:
    records: list[tuple[Path, int, str]] = []
    for path in SOURCE_DOCUMENTS:
        content = path.read_text(encoding="utf-8")
        _, separator, sources = content.partition("## Sources")
        if separator:
            for source_id, url in SOURCE_LINE.findall(sources):
                records.append((path, int(source_id), url))
            continue
        fact_urls = FACT_SOURCE_LINE.findall(content)
        if not fact_urls:
            raise ValueError(f"public source records missing: {path.relative_to(ROOT)}")
        for source_id, url in enumerate(fact_urls, start=1):
            records.append((path, source_id, url))
    return records


def check_url(record: tuple[Path, int, str], timeout: int) -> tuple[Path, int, str, int, str]:
    path, source_id, url = record
    try:
        result = subprocess.run(
            [
                "curl",
                "--location",
                "--silent",
                "--show-error",
                "--output",
                "/dev/null",
                "--max-time",
                str(timeout),
                "--user-agent",
                "tiket-alpha-source-check/1.0",
                "--write-out",
                "%{http_code}",
                url,
            ],
            check=False,
            capture_output=True,
            text=True,
        )
    except OSError as exc:
        return path, source_id, url, 0, str(exc)
    try:
        status = int(result.stdout.strip() or "0")
    except ValueError:
        status = 0
    return path, source_id, url, status, result.stderr.strip()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--timeout", type=int, default=20)
    args = parser.parse_args()

    try:
        records = cited_urls()
    except (OSError, ValueError) as exc:
        print(f"public source check: FAIL\n- {exc}")
        return 1

    failures: list[tuple[Path, int, str, int, str]] = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
        futures = [executor.submit(check_url, record, args.timeout) for record in records]
        for future in concurrent.futures.as_completed(futures):
            result = future.result()
            if not 200 <= result[3] < 400:
                failures.append(result)

    if failures:
        print("public source check: FAIL")
        for path, source_id, url, status, error in sorted(failures):
            detail = error or f"HTTP {status}"
            print(f"- {path.relative_to(ROOT)} [{source_id}] {url}: {detail}")
        return 1

    unique_urls = len({url for _, _, url in records})
    print(f"public source check: PASS ({len(records)} citations, {unique_urls} unique URLs)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
