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

import functools
import hashlib
import json
import os
import time
from collections.abc import Callable
from typing import Any, NamedTuple

import requests

PROMPT_VERSION = "v2"  # bump when the prompt/schema/taxonomy changes -> re-inferences all
OLLAMA_BASE = os.environ.get("OLLAMA_HOST", "http://localhost:11434").rstrip("/")
OLLAMA_URL = OLLAMA_BASE + "/api/chat"
OLLAMA_TAGS_URL = OLLAMA_BASE + "/api/tags"
OLLAMA_CHECK_TIMEOUT_SECONDS = 5
# transient-failure policy shared by every classifier: attempts, per-call
# timeout, and the linear back-off step between attempts (seconds)
CHAT_ATTEMPTS = 3
CHAT_TIMEOUT_SECONDS = 180
CHAT_BACKOFF_SECONDS = 2
# every classifier decodes greedily from a fixed seed with thinking off and the
# output constrained to its JSON schema (see chat_json)
CHAT_OPTIONS: dict[str, Any] = {"temperature": 0, "seed": 1}

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


def content_hash(full_text: str, model: str, prompt_version: str = PROMPT_VERSION) -> str:
    """Stable identity for a (text, model, prompt) triple — the re-inference key."""
    payload = f"{prompt_version}\x00{model}\x00{full_text}".encode()
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


def model_matches(installed: str, wanted: str) -> bool:
    """Whether an installed Ollama tag satisfies `wanted` (a bare name matches its :latest)."""
    return installed == wanted or (":" not in wanted and installed == f"{wanted}:latest")


def installed_models(tags: dict[str, Any]) -> list[str]:
    """The model tags in an Ollama /api/tags answer."""
    return [str(m.get("name", m.get("model", ""))) for m in tags.get("models", [])]


@functools.cache
def ollama_unavailable_reason(model: str) -> str | None:
    """None when Ollama is reachable and `model` is installed; else a one-line
    reason with the fix. Cached per process: every classify-once model asks
    once per build. This is what switches a model into cached-only mode --
    no configuration, the environment is probed."""
    try:
        resp = requests.get(OLLAMA_TAGS_URL, timeout=OLLAMA_CHECK_TIMEOUT_SECONDS)
        resp.raise_for_status()
        names = installed_models(resp.json())
    except (requests.RequestException, ValueError):
        return (
            f"Ollama is not reachable at {OLLAMA_BASE} (install it from https://ollama.com, "
            f"then `ollama pull {model}`; set OLLAMA_HOST if it runs elsewhere)"
        )
    if not any(model_matches(name, model) for name in names):
        return f"model {model!r} is not installed in Ollama at {OLLAMA_BASE} (run `ollama pull {model}`)"
    return None


def chat_json[T](system: str, user: str, model: str, schema: dict[str, Any], parse: Callable[[dict[str, Any]], T]) -> T:
    """One schema-constrained Ollama chat call, parsed by `parse` (which raises
    ValueError/KeyError/TypeError on a malformed or out-of-enum answer). Retries
    transient errors and bad answers alike; raises RuntimeError on repeated failure."""
    body: dict[str, Any] = {
        "model": model,
        "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
        "stream": False,
        "think": False,
        "options": CHAT_OPTIONS,
        "format": schema,
    }
    last_error: Exception | None = None
    for attempt in range(CHAT_ATTEMPTS):
        try:
            resp = requests.post(OLLAMA_URL, json=body, timeout=CHAT_TIMEOUT_SECONDS)
            resp.raise_for_status()
            content: dict[str, Any] = json.loads(resp.json()["message"]["content"])
            return parse(content)
        except (requests.RequestException, KeyError, ValueError, TypeError) as error:
            last_error = error
            time.sleep(CHAT_BACKOFF_SECONDS * (attempt + 1))
    msg = f"classification failed after retries: {last_error}"
    raise RuntimeError(msg)


def clamp_confidence(value: Any) -> float:
    """A model-reported confidence, rounded to 2 places and clamped into [0, 1]."""
    return max(0.0, min(1.0, round(float(value), 2)))


def squash_whitespace(value: Any) -> str:
    """A rationale as one line of single-spaced text."""
    return " ".join(str(value).split())


def classify_one(text: str, model: str, names: list[str], prompt_block: str, schema: dict[str, Any]) -> Label:
    """One Ollama call -> a Label. Retries transient errors; raises on repeated
    failure or an out-of-enum category."""

    def parse(content: dict[str, Any]) -> Label:
        category = str(content["category"])
        if category not in names:
            msg = f"model returned an out-of-enum category: {category!r}"
            raise ValueError(msg)
        return Label(
            category_content=category,
            confidence=clamp_confidence(content["confidence"]),
            is_security_hardening=bool(content["is_security_hardening"]),
            is_performance=bool(content["is_performance"]),
            rationale=squash_whitespace(content.get("reasoning", "")),
        )

    return chat_json(SYSTEM_PROMPT, f'Categories:\n{prompt_block}\n\nFix item: "{text}"', model, schema, parse)
