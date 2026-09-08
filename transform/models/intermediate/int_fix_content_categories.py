# pyright: basic
"""One content-taxonomy label (+ orthogonal security-hardening / performance
flags) per distinct fix, from a local LLM (Ollama) — classify-once, cached by the
fix's CONTENT HASH.

Keyed by a content hash of the fix text, NOT item_ord: item_ord is a volatile
ordinal that shifts when the corpus grows (e.g. pushing FIRST_MAJOR back inserts
earlier fixes and renumbers everything), so a cache keyed on it would re-classify
the whole corpus on any such change. The content hash is the stable identity — a
fix's text is unchanged by adding OTHER majors, so its label is reused across the
shift and only genuinely new/changed text reaches the model.

Materialized as a table (not incremental): item_ord must be recomputed every
build to stay joinable from fct_fixes, so the durable cache is the committed
data/raw/fix_content_categories.csv (the fresh-build fallback), which the
post_hook re-exports. A rebuild on an unchanged corpus is deterministic and calls
nothing; a bulk change (a whole new major) is best pre-populated with
backfill_classifications.py so the build stays fast. Grain = item_ord.
"""

import sys
from decimal import Decimal
from pathlib import Path
from typing import Any

import pyarrow as pa

sys.path.insert(0, str(Path.cwd()))
from sources.classify import (
    PROMPT_VERSION,
    build_schema,
    classify_one,
    content_hash,
    ollama_unavailable_reason,
    taxonomy_prompt,
)

MODEL_TAG = "qwen3:30b-a3b"

# is_classified: false for a fix that was neither cached nor classifiable
# (cached-only mode -- Ollama or the model absent, probed at build time); such
# a row carries NULL labels and is excluded from the CSV export by the post_hook
COLS = [
    "item_ord",
    "content_hash",
    "model",
    "prompt_version",
    "category_content",
    "confidence",
    "is_security_hardening",
    "is_performance",
    "rationale",
    "is_classified",
]
_SCHEMA = pa.schema(
    [
        ("item_ord", pa.int64()),
        ("content_hash", pa.string()),
        ("model", pa.string()),
        ("prompt_version", pa.string()),
        ("category_content", pa.string()),
        ("confidence", pa.decimal128(3, 2)),
        ("is_security_hardening", pa.bool_()),
        ("is_performance", pa.bool_()),
        ("rationale", pa.string()),
        ("is_classified", pa.bool_()),
    ]
)


def _as_bool(value: Any) -> bool:
    return value is True or str(value).strip().lower() == "true"


def model(dbt: Any, session: Any) -> pa.Table:
    dbt.config(materialized="table")

    tax = dbt.ref("content_categories").project("category_order, category, definition").fetchall()
    names, prompt_block = taxonomy_prompt([(int(r[0]), str(r[1]), str(r[2])) for r in tax])
    schema = build_schema(names)

    reps = dbt.ref("int_fix_reps").project("item_ord, full_text").fetchall()

    # durable cache: content_hash -> (category, confidence, is_sec, is_perf, rationale)
    cache: dict[str, tuple[Any, ...]] = {}
    src = dbt.source("inferred", "fix_content_categories")
    for r in src.project(
        "content_hash, category_content, confidence, is_security_hardening, is_performance, rationale"
    ).fetchall():
        cache[str(r[0])] = r

    # cached-only mode when Ollama or the model is absent (probed, not configured)
    unavailable = ollama_unavailable_reason(MODEL_TAG)
    if unavailable is not None:
        print(f"cached-only mode: {unavailable}; unseen fixes are emitted with is_classified = false", file=sys.stderr)

    out: list[tuple[Any, ...]] = []
    for item_ord, full_text in ((int(r[0]), str(r[1])) for r in reps):
        digest = content_hash(full_text, MODEL_TAG)
        seen = cache.get(digest)
        if seen is not None:  # same text -> reuse the label, regardless of item_ord
            out.append(
                (
                    item_ord,
                    digest,
                    MODEL_TAG,
                    PROMPT_VERSION,
                    str(seen[1]),
                    Decimal(str(seen[2])),
                    _as_bool(seen[3]),
                    _as_bool(seen[4]),
                    str(seen[5]),
                    True,
                )
            )
            continue
        if unavailable is not None:
            out.append((item_ord, digest, MODEL_TAG, PROMPT_VERSION, None, None, None, None, None, False))
            continue
        label = classify_one(full_text, MODEL_TAG, names, prompt_block, schema)
        out.append(
            (
                item_ord,
                digest,
                MODEL_TAG,
                PROMPT_VERSION,
                label.category_content,
                Decimal(str(label.confidence)),
                label.is_security_hardening,
                label.is_performance,
                label.rationale,
                True,
            )
        )

    columns: list[Any] = [[row[i] for row in out] for i in range(len(COLS))]
    return pa.table({name: pa.array(columns[i], _SCHEMA.field(i).type) for i, name in enumerate(COLS)})
