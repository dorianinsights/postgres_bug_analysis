#!/usr/bin/env python3
"""Bulk-backfill the AI-involvement label caches -- resumably.

int_commit_ai_involvement / int_thread_ai_involvement classify new texts
in-build, but only up to var(ai_involvement_max_inline_classifications): the
first full scan (~32k texts, ~14 hours at ~2s each), a prompt-version bump, or a
new major is a bulk job. This tool does it RESUMABLY: it classifies every text in
int_commit_ai_texts / int_thread_ai_texts whose content hash isn't already in
data/raw/{commit,thread}_ai_involvement.csv, checkpointing to the CSV every
batch, so an interrupted run just continues. Once the CSVs are complete,
`dbt build` reuses every label and is fast again.

Run `dbt build --select int_commit_ai_texts int_thread_ai_texts` first; Ollama
must be up.

    backfill_ai_involvement.py [--population commit|thread] [--max N] [--candidates-first]

--candidates-first classifies texts matching a wide AI-keyword net before the
rest -- with --max N, that yields the positives a labeling sample needs without
waiting for the whole corpus. The net never EXCLUDES anything: the rest is
classified too, just later.
"""

from __future__ import annotations

import argparse
import csv
import re
import sys
import time
from pathlib import Path
from typing import Any

import duckdb

from pg_analysis.paths import DATA_RAW, SEEDS_DIR, WAREHOUSE
from pg_analysis.sources.ai_involvement import (
    AI_PROMPT_VERSION,
    LABEL_COLS,
    ai_content_hash,
    build_ai_schema,
    classify_ai_one,
    label_to_cells,
    roles_prompt,
)
from pg_analysis.sources.classify import ollama_unavailable_reason

ROLES_SEED = SEEDS_DIR / "ai_involvement_roles.csv"
MODEL_TAG = "qwen3:30b-a3b"
CHECKPOINT_EVERY = 25

# key columns, source query, and cache file per population
POPULATIONS: dict[str, tuple[tuple[str, ...], str, Path]] = {
    "commit": (
        ("fix_key",),
        "SELECT fix_key, ai_text FROM intermediate.int_commit_ai_texts ORDER BY fix_key",
        DATA_RAW / "commit_ai_involvement.csv",
    ),
    "thread": (
        ("list_name", "root_message_id"),
        "SELECT list_name, root_message_id, ai_text FROM intermediate.int_thread_ai_texts ORDER BY list_name, root_message_id",
        DATA_RAW / "thread_ai_involvement.csv",
    ),
}

# the wide net for --candidates-first: anything that could be an AI reference,
# false positives welcome (they only affect ordering)
CANDIDATE_NET = re.compile(
    r"\b(AI|LLM|LLMs|GPT\S*|ChatGPT|Claude|Anthropic|OpenAI|Codex|Gemini|Copilot|Cursor|Devin|"
    r"Big Sleep|Opus|Sonnet|Gemma|Llama|DeepSeek|Mistral|Grok|Aider|Windsurf|Cline|"
    r"language model|machine learning|neural|assistant|agent|agentic|bot|vibe\S*|"
    r"generated|hallucinat\S*|artificial intelligence)\b",
    re.IGNORECASE,
)


def load_by_hash(cache_csv: Path, key_len: int) -> dict[str, list[str]]:
    """content_hash -> its committed CSV row (the durable label cache)."""
    if not cache_csv.is_file():
        return {}
    with cache_csv.open(newline="") as handle:
        reader = csv.reader(handle)
        next(reader, None)  # header
        return {row[key_len]: row for row in reader if row}


def write_cache(cache_csv: Path, header: list[str], rows: dict[tuple[str, ...], list[str]]) -> None:
    tmp = cache_csv.with_suffix(".tmp")
    with tmp.open("w", newline="") as handle:
        writer = csv.writer(handle, lineterminator="\n")
        writer.writerow(header)
        for key in sorted(rows):
            writer.writerow(rows[key])
    tmp.rename(cache_csv)


def fetch_texts(query: str) -> list[tuple[Any, ...]]:
    con = duckdb.connect(str(WAREHOUSE), read_only=True)
    try:
        return con.execute(query).fetchall()
    finally:
        con.close()


def run_population(
    name: str, prompt_block: str, schema: dict[str, Any], limit: int | None, candidates_first: bool
) -> int:
    key_cols, query, cache_csv = POPULATIONS[name]
    header = [*key_cols, *LABEL_COLS]
    texts = fetch_texts(query)
    by_hash = load_by_hash(cache_csv, len(key_cols))
    rows: dict[tuple[str, ...], list[str]] = {}
    todo: list[tuple[tuple[str, ...], str, str]] = []
    for record in texts:
        keys = tuple(str(cell) for cell in record[: len(key_cols)])
        text = str(record[len(key_cols)])
        digest = ai_content_hash(text, MODEL_TAG)
        cached = by_hash.get(digest)
        if cached is not None:  # same text -> reuse the label under the current keys
            rows[keys] = [*keys, *cached[len(key_cols) :]]
        else:
            todo.append((keys, text, digest))
    if candidates_first:
        todo.sort(key=lambda item: 0 if CANDIDATE_NET.search(item[1]) else 1)
    if limit is not None:
        todo = todo[:limit]
    print(f"{name}: {len(texts)} texts, {len(rows)} reused by content hash, {len(todo)} to classify")

    started = time.monotonic()
    for done, (keys, text, digest) in enumerate(todo, start=1):
        label = classify_ai_one(text, MODEL_TAG, prompt_block, schema)
        rows[keys] = [*keys, digest, MODEL_TAG, AI_PROMPT_VERSION, *label_to_cells(label)]
        if done % CHECKPOINT_EVERY == 0:
            write_cache(cache_csv, header, rows)  # resumable checkpoint
            rate = done / (time.monotonic() - started)
            print(f"  {done}/{len(todo)} ({rate:.2f}/s, ~{(len(todo) - done) / rate / 60:.0f} min left)", flush=True)

    write_cache(cache_csv, header, rows)
    print(f"{name}: {len(todo)} classified -> {cache_csv} ({len(rows)} rows)")
    return len(todo)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--population", choices=[*POPULATIONS, "all"], default="all")
    parser.add_argument("--max", type=int, default=None, help="classify at most N texts per population")
    parser.add_argument("--candidates-first", action="store_true", help="classify wide-net keyword hits first")
    args = parser.parse_args()

    if not WAREHOUSE.is_file():
        sys.exit(f"warehouse not found at {WAREHOUSE} -- run `dbt build --select int_*_ai_texts` first")
    unavailable = ollama_unavailable_reason(MODEL_TAG)
    if unavailable is not None:
        sys.exit(f"cannot classify: {unavailable}")
    with ROLES_SEED.open(newline="") as handle:
        roles = [(int(r["role_order"]), r["role"], r["definition"]) for r in csv.DictReader(handle)]
    prompt_block = roles_prompt(roles)
    schema = build_ai_schema()

    names = list(POPULATIONS) if args.population == "all" else [args.population]
    for name in names:
        run_population(name, prompt_block, schema, args.max, args.candidates_first)
    return 0


if __name__ == "__main__":
    sys.exit(main())
