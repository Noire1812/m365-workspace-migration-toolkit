#!/usr/bin/env python3
"""Compare item counts before and after a migration and flag what fell short.

Takes two CSV files with the columns ``account,workload,items``: one with the
counts found in the source tenant, one with the counts that arrived in the
target. Prints a per-workload summary and every account/workload pair that is
missing or below the success threshold.

Exit status: 0 when everything meets the threshold, 1 when something needs
review, 2 for bad input. That makes the script usable as a gate in a delta-sync
checklist ("don't cut over until this exits 0").

Standard library only; Python 3.9+.
"""
from __future__ import annotations

import argparse
import csv
import json
import sys
from dataclasses import asdict, dataclass
from pathlib import Path

REQUIRED_COLUMNS = ("account", "workload", "items")


@dataclass
class Row:
    account: str
    workload: str
    source: int
    target: int
    pct: float
    status: str


def load_counts(path: Path) -> dict[tuple[str, str], int]:
    """Read a counts CSV into {(account, workload): items}, summing duplicates."""
    counts: dict[tuple[str, str], int] = {}
    with path.open(newline="", encoding="utf-8-sig") as fh:
        reader = csv.DictReader(fh)
        header = [h.strip().lower() for h in (reader.fieldnames or [])]
        missing = [c for c in REQUIRED_COLUMNS if c not in header]
        if missing:
            raise ValueError(f"{path}: missing column(s): {', '.join(missing)}")
        for lineno, raw in enumerate(reader, start=2):
            rec = {k.strip().lower(): (v or "").strip() for k, v in raw.items() if k}
            if not rec["account"] and not rec["workload"]:
                continue  # blank line
            try:
                items = int(rec["items"].replace(",", ""))
            except ValueError:
                raise ValueError(f"{path}:{lineno}: items is not a whole number: {rec['items']!r}") from None
            if items < 0:
                raise ValueError(f"{path}:{lineno}: items is negative: {items}")
            key = (rec["account"].lower(), rec["workload"].lower())
            counts[key] = counts.get(key, 0) + items
    return counts


def compare(source: dict, target: dict, threshold: float) -> list[Row]:
    """One Row per account/workload pair seen on either side."""
    rows = []
    for key in sorted(set(source) | set(target)):
        src, tgt = source.get(key, 0), target.get(key, 0)
        if key not in target:
            status = "MISSING_IN_TARGET"
        elif key not in source:
            status = "NOT_IN_SOURCE"
        elif src == 0:
            status = "OK"
        else:
            status = "OK" if tgt / src * 100 >= threshold else "BELOW_THRESHOLD"
        pct = 100.0 if src == 0 else round(tgt / src * 100, 2)
        rows.append(Row(key[0], key[1], src, tgt, pct, status))
    return rows


def summarize(rows: list[Row]) -> dict[str, dict]:
    """Totals per workload, plus an overall line."""
    out: dict[str, dict] = {}
    for r in rows:
        w = out.setdefault(r.workload, {"source": 0, "target": 0, "accounts": 0, "needs_review": 0})
        w["source"] += r.source
        w["target"] += min(r.target, r.source) if r.status != "NOT_IN_SOURCE" else 0
        w["accounts"] += 1
        w["needs_review"] += r.status != "OK"
    total = {"source": 0, "target": 0, "accounts": 0, "needs_review": 0}
    for w in out.values():
        for k in total:
            total[k] += w[k]
    out["ALL"] = total
    for w in out.values():
        w["pct"] = 100.0 if w["source"] == 0 else round(w["target"] / w["source"] * 100, 2)
    return out


def render(summary: dict[str, dict], rows: list[Row]) -> str:
    lines = [f"{'workload':<14}{'source':>12}{'migrated':>12}{'success':>10}{'review':>8}"]
    for name, w in summary.items():
        if name == "ALL":
            lines.append("-" * 56)
        lines.append(f"{name:<14}{w['source']:>12,}{w['target']:>12,}{w['pct']:>9.2f}%{w['needs_review']:>8}")
    flagged = [r for r in rows if r.status != "OK"]
    if flagged:
        lines += ["", "Needs review:"]
        for r in flagged:
            lines.append(f"  {r.status:<18} {r.workload:<12} {r.account:<36} {r.target:,} of {r.source:,} ({r.pct:.2f}%)")
    else:
        lines += ["", "Every account and workload meets the threshold."]
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("source", type=Path, help="CSV of counts found in the source tenant")
    p.add_argument("target", type=Path, help="CSV of counts that arrived in the target")
    p.add_argument("--threshold", type=float, default=99.0, help="minimum success %% per account/workload (default 99)")
    p.add_argument("--json", type=Path, help="also write the full result as JSON to this path")
    args = p.parse_args(argv)

    if not 0 <= args.threshold <= 100:
        print("error: --threshold must be between 0 and 100", file=sys.stderr)
        return 2
    try:
        rows = compare(load_counts(args.source), load_counts(args.target), args.threshold)
    except (OSError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    summary = summarize(rows)
    print(render(summary, rows))
    if args.json:
        args.json.write_text(json.dumps({"threshold": args.threshold, "summary": summary,
                                         "rows": [asdict(r) for r in rows]}, indent=2))
    return 0 if summary["ALL"]["needs_review"] == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
