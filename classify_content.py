#!/usr/bin/env python3
"""Classify each distinct fix into the redesigned 12-category content taxonomy
with a local LLM (Ollama), plus orthogonal is_security_hardening / is_performance
flags. Caches to data/raw/fix_content_categories.csv so dbt reads a stable
artifact — the model is NEVER called inside `dbt build`.

This is the bottom-up replacement for the category_rules regex: the categories
came from the mxbai-embed-large clusters (see embed_fixes.py), are defined in the
content_categories seed, and are assigned per fix by the LLM reading those
definitions. Security is a flag, not a category (is_cve is metadata, from the
fix's CVE list; is_security_hardening is the LLM's read); performance is likewise
a cross-cutting flag. Staged retirement: this lands additively beside the regex
category until it is trusted.

Reads intermediate.int_fix_reps from the warehouse (read-only), so run a
`dbt build` first, with Ollama up and the model pulled (`ollama pull qwen3:30b-a3b`).
Incremental: only fixes whose text (or the model / prompt version) changed are
re-inferred, keyed by a content hash.
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
TAXONOMY_SEED = ROOT / "transform" / "seeds" / "content_categories.csv"
CACHE_CSV = ROOT / "data" / "raw" / "fix_content_categories.csv"

DEFAULT_MODEL = "qwen3:30b-a3b"
PROMPT_VERSION = "v2"  # bump when the prompt/schema/taxonomy changes -> re-inferences all
OLLAMA_URL = os.environ.get("OLLAMA_HOST", "http://localhost:11434").rstrip("/") + "/api/chat"

CACHE_FIELDS = (
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

SYSTEM_PROMPT = (
    "You classify a single PostgreSQL bug-fix release-note item into exactly one content "
    "category — what the fix is fundamentally ABOUT — choosing from the numbered definitions "
    "you are given, by substance rather than surface keywords. Independently, set two flags: "
    "is_security_hardening = true when the fix's essence is closing a security or memory-safety "
    "weakness (buffer overruns, out-of-bounds access, injection, privilege or access-control "
    "issues); is_performance = true when the fix is primarily a performance improvement. A buffer "
    "overrun or out-of-bounds access is NOT the 'Numeric, overflow & limits' category — classify it "
    "by the affected component and set is_security_hardening. These "
    "flags are orthogonal to the category. Respond only through the JSON schema, and fill the "
    "'reasoning' field FIRST — one or two sentences working out what the fix is fundamentally "
    "about — then choose the 'category' consistent with that reasoning, set the two booleans, and "
    "give a confidence in [0, 1]."
)


class Taxonomy(NamedTuple):
    names: list[str]
    prompt_block: str


class Fix(NamedTuple):
    item_ord: int
    full_text: str


class CacheRow(NamedTuple):
    content_hash: str
    model: str
    prompt_version: str
    category_content: str
    confidence: float
    is_security_hardening: bool
    is_performance: bool
    rationale: str


def load_taxonomy() -> Taxonomy:
    with TAXONOMY_SEED.open(newline="") as handle:
        rows = sorted(csv.DictReader(handle), key=lambda r: int(r["category_order"]))
    names = [r["category"] for r in rows]
    block = "\n".join(f"{r['category_order']}. {r['category']} — {r['definition']}" for r in rows)
    return Taxonomy(names=names, prompt_block=block)


def content_hash(full_text: str, model: str) -> str:
    payload = f"{PROMPT_VERSION}\x00{model}\x00{full_text}".encode()
    return hashlib.sha256(payload).hexdigest()[:16]


def fetch_fixes(limit: int | None) -> list[Fix]:
    con = duckdb.connect(str(WAREHOUSE), read_only=True)
    try:
        sql = "SELECT item_ord, full_text FROM intermediate.int_fix_reps ORDER BY item_ord"
        if limit is not None:
            sql += f" LIMIT {limit}"
        rows: list[Any] = con.execute(sql).fetchall()
    finally:
        con.close()
    return [Fix(int(r[0]), str(r[1])) for r in rows]


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
                category_content=row["category_content"],
                confidence=float(row["confidence"]),
                is_security_hardening=row["is_security_hardening"] == "true",
                is_performance=row["is_performance"] == "true",
                rationale=row["rationale"],
            )
    return cache


def write_cache(cache: dict[int, CacheRow]) -> None:
    CACHE_CSV.parent.mkdir(parents=True, exist_ok=True)
    tmp = CACHE_CSV.with_suffix(".tmp")
    with tmp.open("w", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(CACHE_FIELDS)
        for item_ord in sorted(cache):
            r = cache[item_ord]
            writer.writerow(
                [
                    item_ord,
                    r.content_hash,
                    r.model,
                    r.prompt_version,
                    r.category_content,
                    r.confidence,
                    str(r.is_security_hardening).lower(),
                    str(r.is_performance).lower(),
                    r.rationale,
                ]
            )
    tmp.rename(CACHE_CSV)


def build_schema(names: list[str]) -> dict[str, Any]:
    # 'reasoning' first so the constrained decoder emits the analysis BEFORE it
    # commits to a category (chain-of-thought via property order).
    return {
        "type": "object",
        "properties": {
            "reasoning": {"type": "string"},
            "category": {"type": "string", "enum": names},
            "is_security_hardening": {"type": "boolean"},
            "is_performance": {"type": "boolean"},
            "confidence": {"type": "number"},
        },
        "required": ["reasoning", "category", "is_security_hardening", "is_performance", "confidence"],
    }


def classify(text: str, model: str, taxonomy: Taxonomy, schema: dict[str, Any]) -> CacheRow:
    body: dict[str, Any] = {
        "model": model,
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": f'Categories:\n{taxonomy.prompt_block}\n\nFix item: "{text}"'},
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
            if category not in taxonomy.names:
                msg = f"model returned an out-of-enum category: {category!r}"
                raise ValueError(msg)
            return CacheRow(
                content_hash="",  # filled by the caller
                model=model,
                prompt_version=PROMPT_VERSION,
                category_content=category,
                confidence=max(0.0, min(1.0, round(float(content["confidence"]), 2))),
                is_security_hardening=bool(content["is_security_hardening"]),
                is_performance=bool(content["is_performance"]),
                rationale=" ".join(str(content.get("reasoning", "")).split()),
            )
        except (requests.RequestException, KeyError, ValueError, TypeError) as error:
            last_error = error
            time.sleep(2 * (attempt + 1))
    msg = f"classification failed after retries: {last_error}"
    raise RuntimeError(msg)


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="LLM-classify fixes into the content taxonomy (Ollama).")
    parser.add_argument("--model", default=DEFAULT_MODEL, help=f"Ollama model tag (default: {DEFAULT_MODEL})")
    parser.add_argument("--limit", type=int, default=None, help="classify only the first N fixes (smoke test)")
    parser.add_argument("--force", action="store_true", help="re-infer every fix, ignoring the cache")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    if not WAREHOUSE.is_file():
        sys.exit(f"warehouse not found at {WAREHOUSE} — run a dbt build first")

    taxonomy = load_taxonomy()
    schema = build_schema(taxonomy.names)
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
        row = classify(fix.full_text, args.model, taxonomy, schema)
        cache[fix.item_ord] = row._replace(content_hash=digest)
        inferred += 1
        if inferred % 25 == 0:
            write_cache(cache)
            rate = inferred / (time.monotonic() - started)
            print(f"  {index}/{len(fixes)} ({inferred} inferred, {rate:.1f}/s)", flush=True)

    write_cache(cache)
    print(f"done: {inferred} inferred, {reused} reused -> {CACHE_CSV} ({len(cache)} rows)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
