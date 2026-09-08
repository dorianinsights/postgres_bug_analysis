# pyright: basic
# (basic, like the dbt Python models it serves: pyarrow's stubs leave
# pa.array / pa.table partially unknown under strict)
"""The parts the two AI-involvement dbt Python models share: the model tag,
the Ollama availability probe that switches a build into cached-only mode, and
the typed pyarrow table (NULL-tolerant, for the unclassified rows of
cached-only mode). No dbt.ref() lives here on purpose: dbt discovers a Python
model's refs by scanning the model file itself."""

from __future__ import annotations

import sys
from collections.abc import Sequence
from decimal import Decimal
from typing import Any

import pyarrow as pa

from sources.ai_involvement import Classifier, as_bool
from sources.classify import ollama_unavailable_reason

MODEL_TAG = "qwen3:30b-a3b"

# every output column's type; key columns are strings
LABEL_TYPES: dict[str, Any] = {
    "content_hash": pa.string(),
    "model": pa.string(),
    "prompt_version": pa.string(),
    "ai_found": pa.bool_(),
    "ai_analyzed": pa.bool_(),
    "ai_authored": pa.bool_(),
    "ai_tooling": pa.bool_(),
    "mentioned_only": pa.bool_(),
    "vendor": pa.string(),
    "disclosure_form": pa.string(),
    "confidence": pa.decimal128(3, 2),
    "rationale": pa.string(),
    "is_classified": pa.bool_(),
}


def resolve_classifier(classify: Classifier) -> Classifier | None:
    """`classify` when Ollama and the model are available, else None (cached-only
    mode), with the reason printed into the dbt log."""
    reason = ollama_unavailable_reason(MODEL_TAG)
    if reason is None:
        return classify
    print(f"cached-only mode: {reason}; unseen texts are emitted with is_classified = false", file=sys.stderr)
    return None


def _typed(values: list[Any], typ: Any) -> pa.Array[Any]:
    if pa.types.is_boolean(typ):
        return pa.array([None if v is None else as_bool(v) for v in values], typ)
    if pa.types.is_decimal(typ):
        return pa.array([None if v is None else Decimal(str(v)) for v in values], typ)
    return pa.array([None if v is None else str(v) for v in values], typ)


def involvement_table(key_cols: Sequence[str], output_cols: Sequence[str], rows: list[list[Any]]) -> pa.Table:
    """Rows of key cells + output cells -> a typed pyarrow table."""
    names = [*key_cols, *output_cols]
    arrays: dict[str, pa.Array[Any]] = {
        name: _typed([row[i] for row in rows], LABEL_TYPES.get(name, pa.string())) for i, name in enumerate(names)
    }
    return pa.table(arrays)
