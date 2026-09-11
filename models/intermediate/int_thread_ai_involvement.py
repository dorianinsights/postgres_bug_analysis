# pyright: basic
"""Disclosed AI involvement per mailing-list thread (its root message), from a
local LLM (Ollama) reading int_thread_ai_texts -- classify-once, cached by the
text's CONTENT HASH in the committed data/raw/thread_ai_involvement.csv (the
fresh-build fallback, re-exported by the post_hook). Only genuinely new or
changed text reaches the model, and a build classifies at most
var(ai_involvement_max_inline_classifications) texts inline -- a bulk change
goes through backfill_ai_involvement.py.

Cached-only mode: when Ollama is not reachable or the model tag is not installed
(probed, not configured), the cached labels are emitted as-is and every unseen
text gets NULL labels with is_classified = false -- the build succeeds and the
is_classified warn test reports how many rows are waiting.
Grain = (list_name, root_message_id).
"""

from typing import Any

import pyarrow as pa

from pg_analysis.sources.ai_involvement import (
    LABEL_COLS,
    OUTPUT_COLS,
    build_ai_schema,
    classify_ai_one,
    label_rows,
    roles_prompt,
)
from pg_analysis.sources.ai_model_table import MODEL_TAG, involvement_table, resolve_classifier

KEY_COLS = ("list_name", "root_message_id")


def model(dbt: Any, session: Any) -> pa.Table:
    dbt.config(materialized="table")
    max_inline = int(dbt.config.get("max_inline_classifications"))

    # dbt discovers refs by scanning THIS file: keep the ref literal here
    roles = dbt.ref("ai_involvement_roles").project("role_order, role, definition").fetchall()
    prompt_block = roles_prompt([(int(r[0]), str(r[1]), str(r[2])) for r in roles])
    schema = build_ai_schema()
    classify = resolve_classifier(lambda text: classify_ai_one(text, MODEL_TAG, prompt_block, schema))

    texts = dbt.ref("int_thread_ai_texts").project("list_name, root_message_id, ai_text").fetchall()
    cache: dict[str, tuple[Any, ...]] = {}
    for r in dbt.source("inferred", "thread_ai_involvement").project(", ".join(LABEL_COLS)).fetchall():
        cache[str(r[0])] = tuple(r)

    rows = label_rows(
        (((str(r[0]), str(r[1])), str(r[2])) for r in texts), cache, MODEL_TAG, classify, max_inline=max_inline
    )
    return involvement_table(KEY_COLS, OUTPUT_COLS, rows)
