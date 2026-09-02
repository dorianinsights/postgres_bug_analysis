#!/usr/bin/env python3
"""Bulk-backfill fix content classifications into the committed CSV — resumably.

The int_fix_content_categories model classifies new fixes in-build; for a handful
that is fine, but a BULK change — extending the corpus by a whole major adds
hundreds of fixes at once — makes a single build take many minutes with no
mid-run checkpoint. This offline tool does that backfill RESUMABLY: it classifies
every fix in int_fix_reps whose text isn't already in
data/raw/fix_content_categories.csv, checkpointing to the CSV every batch, so an
interrupted run just continues. Once the CSV is complete, `dbt build` reuses
every label and is fast again.

Cached by the fix CONTENT HASH (stable across corpus renumbering), exactly like
the model — so growing the corpus reuses existing labels and only classifies the
genuinely new text. Run `dbt run --select int_fix_reps` first; Ollama must be up.
"""

from __future__ import annotations

import csv
import sys
import time
from pathlib import Path
from typing import Any

import duckdb

sys.path.insert(0, str(Path(__file__).parent / "transform"))
from sources.classify import PROMPT_VERSION, build_schema, classify_one, content_hash, taxonomy_prompt

ROOT = Path(__file__).parent
WAREHOUSE = ROOT / "transform" / "transform.duckdb"
TAXONOMY_SEED = ROOT / "transform" / "seeds" / "content_categories.csv"
CACHE_CSV = ROOT / "data" / "raw" / "fix_content_categories.csv"
MODEL_TAG = "qwen3:30b-a3b"

# Column order + line ending match the dbt model's CSV export, so no churn.
COLS = (
    "item_ord",
    "content_hash",
    "model",
    "prompt_version",
    "category_content",
    "confidence",
    "is_security_hardening",
    "is_performance",
    "rationale",
)


def load_by_hash() -> dict[str, list[str]]:
    """content_hash -> its committed CSV row (the durable label cache)."""
    if not CACHE_CSV.is_file():
        return {}
    with CACHE_CSV.open(newline="") as handle:
        return {row[1]: row for row in csv.reader(handle) if row and row[0] != "item_ord"}


def write_cache(rows: dict[int, list[str]]) -> None:
    tmp = CACHE_CSV.with_suffix(".tmp")
    with tmp.open("w", newline="") as handle:
        writer = csv.writer(handle, lineterminator="\n")
        writer.writerow(COLS)
        for item_ord in sorted(rows):
            writer.writerow(rows[item_ord])
    tmp.rename(CACHE_CSV)


def main() -> int:
    if not WAREHOUSE.is_file():
        sys.exit(f"warehouse not found at {WAREHOUSE} — run `dbt run --select int_fix_reps` first")

    with TAXONOMY_SEED.open(newline="") as handle:
        tax = [(int(r["category_order"]), r["category"], r["definition"]) for r in csv.DictReader(handle)]
    names, prompt_block = taxonomy_prompt(tax)
    schema = build_schema(names)

    con = duckdb.connect(str(WAREHOUSE), read_only=True)
    try:
        fixes: list[Any] = con.execute(
            "SELECT item_ord, full_text FROM intermediate.int_fix_reps ORDER BY item_ord"
        ).fetchall()
    finally:
        con.close()

    by_hash = load_by_hash()
    rows: dict[int, list[str]] = {}
    todo: list[tuple[int, str, str]] = []
    for item_ord, full_text in ((int(r[0]), str(r[1])) for r in fixes):
        digest = content_hash(full_text, MODEL_TAG)
        cached = by_hash.get(digest)
        if cached is not None:  # same text -> reuse label under the current item_ord
            rows[item_ord] = [str(item_ord), *cached[1:]]
        else:
            todo.append((item_ord, full_text, digest))
    print(f"{len(fixes)} fixes, {len(rows)} reused by content hash, {len(todo)} to classify")

    started = time.monotonic()
    for done, (item_ord, full_text, digest) in enumerate(todo, start=1):
        label = classify_one(full_text, MODEL_TAG, names, prompt_block, schema)
        rows[item_ord] = [
            str(item_ord),
            digest,
            MODEL_TAG,
            PROMPT_VERSION,
            label.category_content,
            f"{label.confidence:.2f}",
            str(label.is_security_hardening).lower(),
            str(label.is_performance).lower(),
            label.rationale,
        ]
        if done % 25 == 0:
            write_cache(rows)  # resumable checkpoint
            print(f"  {done}/{len(todo)} ({done / (time.monotonic() - started):.1f}/s)", flush=True)

    write_cache(rows)
    print(f"done: {len(todo)} classified -> {CACHE_CSV} ({len(rows)} rows)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
