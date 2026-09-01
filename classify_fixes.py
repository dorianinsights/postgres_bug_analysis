#!/usr/bin/env python3
"""Classify each distinct fix's release-note text into a content category with a
local LLM (Ollama), caching the result so dbt reads a stable CSV — the model is
NEVER called inside `dbt build`.

Phase 1 is an AUDIT of the regex classifier (the category_rules seed applied in
int_fix_reps): this writes data/raw/fix_categories_llm.csv (one row per distinct
fix), which stg_fix_categories_llm + the fix_category_audit / _agreement_agg
marts compare against the regex `category`.

Determinism, the repo's core value: like the scrapers, inference happens HERE
(offline), the CSV is the committed artifact, and rebuilds just read it back.
Re-running is explicit and INCREMENTAL — only fixes whose text (or the model /
prompt version) changed are re-inferred, keyed by a content hash. The regex
already labels CVEs "Security (CVE)" from metadata, not text, so the LLM chooses
only among the nine CONTENT categories; the audit reads the CVE flag separately.

Prerequisites: a `dbt build` has run (this reads intermediate.int_fix_reps from
the warehouse, read-only), and Ollama is running locally with the model pulled
(`ollama pull qwen3:30b-a3b`).
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
import sys
import time
from pathlib import Path
from typing import Any, NamedTuple

import duckdb
import requests

ROOT = Path(__file__).parent
WAREHOUSE = ROOT / "transform" / "transform.duckdb"
CATEGORIES_SEED = ROOT / "transform" / "seeds" / "categories.csv"
CACHE_CSV = ROOT / "data" / "raw" / "fix_categories_llm.csv"

DEFAULT_MODEL = "qwen3:30b-a3b"
PROMPT_VERSION = "v2"  # bump when the prompt/schema changes -> re-inferences all
OLLAMA_URL = os.environ.get("OLLAMA_HOST", "http://localhost:11434").rstrip("/") + "/api/chat"
CVE_CATEGORY = "Security (CVE)"  # assigned by rule from metadata, not the LLM

CACHE_FIELDS = ("item_ord", "content_hash", "model", "prompt_version", "category_llm", "confidence", "rationale")

SYSTEM_PROMPT = (
    "You classify a single PostgreSQL bug-fix release-note item into exactly one of "
    "the allowed content categories, based on what the fix is fundamentally ABOUT — "
    "its substance, not surface keywords. One category, 'Security hardening (no CVE)', "
    "is for fixes whose essence is closing a security or memory-safety weakness (e.g. "
    "buffer overflows, out-of-bounds access, injection, privilege or access-control "
    "issues); choose it when that is the primary point of the fix, rather than a "
    "downstream symptom like a crash. Respond only through the given JSON schema: the "
    "category (one allowed value), a confidence in [0, 1], and a one-sentence rationale."
)


class Fix(NamedTuple):
    item_ord: int
    full_text: str
    category_regex: str


class CacheRow(NamedTuple):
    content_hash: str
    model: str
    prompt_version: str
    category_llm: str
    confidence: float
    rationale: str


def load_content_categories() -> list[str]:
    """The nine content categories = the seed's categories minus 'Security (CVE)'
    (which is a metadata rule, not a text judgment). Read from the seed so the
    label set stays in lockstep with the regex classifier."""
    with CATEGORIES_SEED.open(newline="") as handle:
        return [row["category"] for row in csv.DictReader(handle) if row["category"] != CVE_CATEGORY]


def content_hash(full_text: str, model: str) -> str:
    """Stable identity for a (text, model, prompt) triple — re-inference key."""
    payload = f"{PROMPT_VERSION}\x00{model}\x00{full_text}".encode()
    return hashlib.sha256(payload).hexdigest()[:16]


def fetch_fixes(limit: int | None) -> list[Fix]:
    con = duckdb.connect(str(WAREHOUSE), read_only=True)
    try:
        sql = "SELECT item_ord, full_text, category FROM intermediate.int_fix_reps ORDER BY item_ord"
        if limit is not None:
            sql += f" LIMIT {limit}"
        rows: list[Any] = con.execute(sql).fetchall()
    finally:
        con.close()
    return [Fix(item_ord=int(r[0]), full_text=str(r[1]), category_regex=str(r[2])) for r in rows]


def load_cache() -> dict[int, CacheRow]:
    if not CACHE_CSV.is_file():
        return {}
    cache: dict[int, CacheRow] = {}
    with CACHE_CSV.open(newline="") as handle:
        for row in csv.DictReader(handle):
            cache[int(row["item_ord"])] = CacheRow(
                content_hash=row["content_hash"],
                model=row["model"],
                prompt_version=row["prompt_version"],
                category_llm=row["category_llm"],
                confidence=float(row["confidence"]),
                rationale=row["rationale"],
            )
    return cache


def write_cache(cache: dict[int, CacheRow]) -> None:
    """Atomically rewrite the whole cache (one row per fix, item_ord order)."""
    CACHE_CSV.parent.mkdir(parents=True, exist_ok=True)
    tmp = CACHE_CSV.with_suffix(".tmp")
    with tmp.open("w", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(CACHE_FIELDS)
        for item_ord in sorted(cache):
            row = cache[item_ord]
            writer.writerow(
                [
                    item_ord,
                    row.content_hash,
                    row.model,
                    row.prompt_version,
                    row.category_llm,
                    row.confidence,
                    row.rationale,
                ]
            )
    tmp.rename(CACHE_CSV)


def classify(text: str, model: str, categories: list[str], schema: dict[str, Any]) -> tuple[str, float, str]:
    """One Ollama call -> (category, confidence, rationale). Retries transient
    errors; raises on repeated failure or an out-of-enum label."""
    body: dict[str, Any] = {
        "model": model,
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": f'Allowed categories: {categories}\n\nFix item: "{text}"'},
        ],
        "stream": False,
        "think": False,
        "options": {"temperature": 0, "seed": 1},
        "format": schema,
    }
    last_error: Exception | None = None
    for attempt in range(3):
        try:
            resp = requests.post(OLLAMA_URL, json=body, timeout=180)
            resp.raise_for_status()
            content: dict[str, Any] = json.loads(resp.json()["message"]["content"])
            category = str(content["category"])
            if category not in categories:
                msg = f"model returned an out-of-enum category: {category!r}"
                raise ValueError(msg)
            confidence = max(0.0, min(1.0, round(float(content["confidence"]), 2)))
            rationale = " ".join(str(content.get("rationale", "")).split())  # collapse to one CSV-safe line
            return category, confidence, rationale
        except (requests.RequestException, KeyError, ValueError) as error:
            last_error = error
            time.sleep(2 * (attempt + 1))
    msg = f"classification failed after retries: {last_error}"
    raise RuntimeError(msg)


def build_schema(categories: list[str]) -> dict[str, Any]:
    return {
        "type": "object",
        "properties": {
            "category": {"type": "string", "enum": categories},
            "confidence": {"type": "number"},
            "rationale": {"type": "string"},
        },
        "required": ["category", "confidence", "rationale"],
    }


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="LLM-classify PostgreSQL fixes into content categories (Ollama).")
    parser.add_argument("--model", default=DEFAULT_MODEL, help=f"Ollama model tag (default: {DEFAULT_MODEL})")
    parser.add_argument("--limit", type=int, default=None, help="classify only the first N fixes (smoke test)")
    parser.add_argument("--force", action="store_true", help="re-infer every fix, ignoring the cache")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    if not WAREHOUSE.is_file():
        sys.exit(f"warehouse not found at {WAREHOUSE} — run a dbt build first")

    categories = load_content_categories()
    schema = build_schema(categories)
    fixes = fetch_fixes(args.limit)
    cache = {} if args.force else load_cache()

    inferred = reused = 0
    started = time.monotonic()
    for index, fix in enumerate(fixes, start=1):
        digest = content_hash(fix.full_text, args.model)
        cached = cache.get(fix.item_ord)
        if cached is not None and cached.content_hash == digest and cached.prompt_version == PROMPT_VERSION:
            reused += 1
            continue
        category, confidence, rationale = classify(fix.full_text, args.model, categories, schema)
        cache[fix.item_ord] = CacheRow(digest, args.model, PROMPT_VERSION, category, confidence, rationale)
        inferred += 1
        if inferred % 25 == 0:
            write_cache(cache)  # checkpoint so an interrupted run keeps progress
            rate = inferred / (time.monotonic() - started)
            print(f"  {index}/{len(fixes)} ({inferred} inferred, {rate:.1f}/s)", flush=True)

    write_cache(cache)
    print(f"done: {inferred} inferred, {reused} reused from cache -> {CACHE_CSV} ({len(cache)} rows)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
