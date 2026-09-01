#!/usr/bin/env python3
"""Embed each distinct fix's release-note text into a vector with a local model
(Ollama nomic-embed-text), for BOTTOM-UP exploration — clustering, dedup, and
nearest-neighbour experiments — as opposed to the top-down category classifiers.

Prototype scope: writes .cache/fix_embeddings.parquet (gitignored, like the
clone and mbox caches), one row per distinct fix with its 768-d vector, the
regex category, and the summary. Unlike classify_fixes.py this is not (yet)
wired into dbt — it feeds the exploratory clustering step.

Reads intermediate.int_fix_reps from the warehouse (read-only), so run a
`dbt build` first, with Ollama up and the model pulled
(`ollama pull nomic-embed-text`).
"""

from __future__ import annotations

import argparse
import os
import sys
import time
from pathlib import Path
from typing import Any, NamedTuple

import duckdb
import pyarrow as pa
import pyarrow.parquet as pq
import requests

ROOT = Path(__file__).parent
WAREHOUSE = ROOT / "transform" / "transform.duckdb"
CACHE_DIR = ROOT / ".cache"

DEFAULT_MODEL = "nomic-embed-text"
EMBED_URL = os.environ.get("OLLAMA_HOST", "http://localhost:11434").rstrip("/") + "/api/embed"
BATCH = 64


def out_parquet(model: str) -> Path:
    """Per-model cache path, so several embedding models can be compared."""
    slug = model.replace(":", "-").replace("/", "-")
    return CACHE_DIR / f"fix_embeddings_{slug}.parquet"


class Fix(NamedTuple):
    item_ord: int
    summary: str
    full_text: str
    category_regex: str


def fetch_fixes() -> list[Fix]:
    con = duckdb.connect(str(WAREHOUSE), read_only=True)
    try:
        rows: list[Any] = con.execute(
            "SELECT item_ord, summary, full_text, category FROM intermediate.int_fix_reps ORDER BY item_ord"
        ).fetchall()
    finally:
        con.close()
    return [Fix(int(r[0]), str(r[1]), str(r[2]), str(r[3])) for r in rows]


def embed_batch(texts: list[str], model: str) -> list[list[float]]:
    """Embed a batch of texts in one call, with a couple of retries."""
    last_error: Exception | None = None
    for attempt in range(3):
        try:
            resp = requests.post(EMBED_URL, json={"model": model, "input": texts}, timeout=180)
            resp.raise_for_status()
            vectors: Any = resp.json()["embeddings"]
            return [[float(x) for x in vector] for vector in vectors]
        except (requests.RequestException, KeyError, ValueError, TypeError) as error:
            last_error = error
            time.sleep(2 * (attempt + 1))
    msg = f"embedding failed after retries: {last_error}"
    raise RuntimeError(msg)


def main() -> int:
    parser = argparse.ArgumentParser(description="Embed fixes with an Ollama model, for clustering experiments.")
    parser.add_argument("--model", default=DEFAULT_MODEL, help=f"Ollama embedding model (default: {DEFAULT_MODEL})")
    args = parser.parse_args()

    if not WAREHOUSE.is_file():
        sys.exit(f"warehouse not found at {WAREHOUSE} — run a dbt build first")

    fixes = fetch_fixes()
    embeddings: list[list[float]] = []
    started = time.monotonic()
    for start in range(0, len(fixes), BATCH):
        chunk = fixes[start : start + BATCH]
        embeddings.extend(embed_batch([fix.full_text for fix in chunk], args.model))
        done = start + len(chunk)
        print(f"  {done}/{len(fixes)} embedded ({done / (time.monotonic() - started):.0f}/s)", flush=True)

    out = out_parquet(args.model)
    out.parent.mkdir(parents=True, exist_ok=True)
    columns = {
        "item_ord": pa.array([fix.item_ord for fix in fixes], pa.int64()),
        "category_regex": pa.array([fix.category_regex for fix in fixes], pa.string()),
        "summary": pa.array([fix.summary for fix in fixes], pa.string()),
        "embedding": pa.array(embeddings, pa.list_(pa.float32())),
    }
    # pyarrow-stubs don't fully type these two parquet-I/O calls; the rest stays strict.
    table = pa.table(columns)  # pyright: ignore[reportUnknownMemberType]
    pq.write_table(table, out)  # pyright: ignore[reportUnknownMemberType]
    print(f"wrote {table.num_rows} embeddings ({len(embeddings[0])}-d, {args.model}) -> {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
