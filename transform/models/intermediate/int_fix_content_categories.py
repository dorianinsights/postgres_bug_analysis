# pyright: basic
"""One content-taxonomy label (+ orthogonal security-hardening / performance
flags) per distinct fix, from a local LLM (Ollama) — an INCREMENTAL, classify-once
model.

Each fix is classified a single time, keyed by a content hash of its text (so a
text change re-triggers it). Existing labels are read back untouched: on an
incremental run only new-or-changed fixes reach the model; on a fresh build the
committed data/raw/fix_content_categories.csv is the fallback seed, so a clone
with a current CSV classifies nothing and needs no model. A post-hook re-exports
that CSV so it stays current. See sources/classify.py for the determinism note.

Grain = item_ord. Replaces the offline classify_content.py; feeds fct_fixes.
"""

import sys
from decimal import Decimal
from pathlib import Path
from typing import Any

import pyarrow as pa

sys.path.insert(0, str(Path.cwd()))
from sources.classify import PROMPT_VERSION, build_schema, classify_one, content_hash, taxonomy_prompt

MODEL_TAG = "qwen3:30b-a3b"

# Output column order — shared by the warehouse table and the committed CSV.
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
    ]
)
_COL_SQL = "item_ord, content_hash, model, prompt_version, category_content, confidence, is_security_hardening, is_performance, rationale"


def _as_bool(value: Any) -> bool:
    return value is True or str(value).strip().lower() == "true"


def model(dbt: Any, session: Any) -> pa.Table:
    dbt.config(materialized="incremental", unique_key="item_ord")

    tax = dbt.ref("content_categories").project("category_order, category, definition").fetchall()
    names, prompt_block = taxonomy_prompt([(int(r[0]), str(r[1]), str(r[2])) for r in tax])
    schema = build_schema(names)

    reps = dbt.ref("int_fix_reps").project("item_ord, full_text").fetchall()

    # existing labels: the warehouse table on an incremental run, else the CSV seed.
    # _COL_SQL is a fixed constant and dbt.this is a dbt-managed identifier -> S608 is a false positive.
    if dbt.is_incremental:
        prior_rows = session.sql(f"SELECT {_COL_SQL} FROM {dbt.this}").fetchall()  # noqa: S608
    else:
        prior_rows = dbt.source("inferred", "fix_content_categories").project(_COL_SQL).fetchall()
    prior = {int(r[0]): r for r in prior_rows}

    out: list[tuple[Any, ...]] = []
    for item_ord, full_text in ((int(r[0]), str(r[1])) for r in reps):
        digest = content_hash(full_text, MODEL_TAG)
        seen = prior.get(item_ord)
        if seen is not None and str(seen[1]) == digest:  # unchanged text/model/prompt -> reuse
            if not dbt.is_incremental:  # a full refresh must re-emit the whole table
                out.append(
                    (
                        item_ord,
                        digest,
                        str(seen[2]),
                        str(seen[3]),
                        str(seen[4]),
                        Decimal(str(seen[5])),
                        _as_bool(seen[6]),
                        _as_bool(seen[7]),
                        str(seen[8]),
                    )
                )
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
            )
        )

    columns: list[Any] = [[row[i] for row in out] for i in range(len(COLS))]
    return pa.table({name: pa.array(columns[i], _SCHEMA.field(i).type) for i, name in enumerate(COLS)})
