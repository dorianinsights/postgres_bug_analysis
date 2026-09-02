# pyright: strict
"""Local-LLM fix classification for the int_fix_content_categories dbt model.

The model is INCREMENTAL and classify-once: each fix is classified a single time
(keyed by a content hash of its text) and the result is read back forever, so a
rebuild on an unchanged corpus is deterministic and needs no model call. Only new
fixes, or fixes whose text changed, are (re)classified — and only then does the
build reach out to Ollama. The committed data/raw/fix_content_categories.csv is
the fresh-build fallback (a clone with a current CSV classifies nothing).

Determinism note: Ollama is called with temperature 0 and a fixed seed and its
output is constrained to the JSON schema below; the cache — not the model's
bit-for-bit reproducibility — is what guarantees stable rebuilds.
"""

from __future__ import annotations

import hashlib
import json
import os
import time
from typing import Any, NamedTuple

import requests

PROMPT_VERSION = "v2"  # bump when the prompt/schema/taxonomy changes -> re-inferences all
OLLAMA_URL = os.environ.get("OLLAMA_HOST", "http://localhost:11434").rstrip("/") + "/api/chat"

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


class Label(NamedTuple):
    category_content: str
    confidence: float
    is_security_hardening: bool
    is_performance: bool
    rationale: str


def content_hash(full_text: str, model: str) -> str:
    """Stable identity for a (text, model, prompt) triple — the re-inference key."""
    payload = f"{PROMPT_VERSION}\x00{model}\x00{full_text}".encode()
    return hashlib.sha256(payload).hexdigest()[:16]


def taxonomy_prompt(rows: list[tuple[int, str, str]]) -> tuple[list[str], str]:
    """(category names, numbered-definitions prompt block) from content_categories rows
    of (category_order, category, definition), ordered by category_order."""
    ordered = sorted(rows, key=lambda r: r[0])
    names = [name for _, name, _ in ordered]
    block = "\n".join(f"{order}. {name} — {definition}" for order, name, definition in ordered)
    return names, block


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


def classify_one(text: str, model: str, names: list[str], prompt_block: str, schema: dict[str, Any]) -> Label:
    """One Ollama call -> a Label. Retries transient errors; raises on repeated
    failure or an out-of-enum category."""
    body: dict[str, Any] = {
        "model": model,
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": f'Categories:\n{prompt_block}\n\nFix item: "{text}"'},
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
            if category not in names:
                msg = f"model returned an out-of-enum category: {category!r}"
                raise ValueError(msg)
            return Label(
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
