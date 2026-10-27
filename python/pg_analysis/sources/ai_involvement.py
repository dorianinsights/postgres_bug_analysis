# pyright: strict
"""Local-LLM AI-involvement classification: did this text DISCLOSE that an AI
tool took part in the work, and in what role?

Shared by the int_commit_ai_involvement / int_thread_ai_involvement dbt models
and backfill_ai_involvement.py. Same classify-once design as sources/classify.py:
each text is classified a single time (keyed by a content hash of text + model +
prompt version) and the label is read back from the committed CSV forever, so a
rebuild on an unchanged corpus calls nothing.

What the model reads is a DISCLOSURE. It cannot see undisclosed AI use, so the
flags measure "disclosed AI involvement" -- a rising line partly measures
changing disclosure norms (PostgreSQL had no AI policy as of mid-2026), which is
why disclosure_form is recorded alongside the roles.
"""

from __future__ import annotations

import re
from collections.abc import Callable, Iterable, Mapping, Sequence
from typing import Any, Literal, NamedTuple

from pydantic import BaseModel

from pg_analysis.sources.classify import chat_json, clamp_confidence, content_hash, squash_whitespace

# bump when the prompt/schema/roles change -> re-inferences all. Namespaced so
# it can never collide with sources.classify.PROMPT_VERSION in the hash space.
AI_PROMPT_VERSION = "ai-v5"

# the mention hint (see hint_lines): AI vendor/product names and the generic
# terms, deliberately WITHOUT the noisy ordinary words (cursor, model, agent,
# bot, generated) -- those only cost attention, and the model reads the whole
# text anyway
HINT_NET = re.compile(
    r"\b(AI|LLMs?|GPT\S*|Chat-?GPT|Claude|Anthropic|OpenAI|Codex|Gemini|Copilot|Devin|Big Sleep|Opus|Sonnet|"
    r"Haiku|Fable|Mythos|Gemma|Llama|DeepSeek|Mistral|Grok|Aider|Windsurf|Cline|language models?|"
    r"agentic|vibe\S*|hallucinat\S*|artificial intelligence|AI-\w+)\b",
    re.IGNORECASE,
)
HINT_MAX_LINES = 12
HINT_LINE_CHARS = 200

# The categories of AI involvement the model can set, and the vendor/disclosure enums.
WORK_ROLE_FLAGS = ("ai_found", "ai_analyzed", "ai_authored", "ai_tooling")
ROLE_FLAGS = (*WORK_ROLE_FLAGS, "mentioned_only")
Vendor = Literal["anthropic", "openai", "google", "microsoft", "other", "unspecified", "none"]
DisclosureForm = Literal["trailer", "prose", "disclaimer", "none"]
# label columns as they land in the cache CSV and the model output, after the
# grain's key column(s)
LABEL_COLS = (
    "content_hash",
    "model",
    "prompt_version",
    *ROLE_FLAGS,
    "vendor",
    "disclosure_form",
    "confidence",
    "rationale",
)

SYSTEM_PROMPT = (
    "You read one PostgreSQL development artifact -- a git commit message or the first message of "
    "a mailing-list thread -- and decide whether the text DISCLOSES that an AI tool took part in the "
    "work, and in which roles, using the numbered role definitions you are given.\n"
    "\n"
    "WHAT COUNTS AS AN AI TOOL: a large language model, coding agent or assistant. Names: Claude, "
    "Claude Code, and the Claude model names Opus, Sonnet, Haiku, Fable, Mythos (all -> vendor "
    "anthropic); ChatGPT, Chat-GPT, GPT, Codex, OpenAI (-> openai); Gemini, Big Sleep, Jules "
    "(-> google); Copilot (-> microsoft); any other named AI product (-> other); a bare 'AI', "
    "'LLM', 'my AI tool', 'AI harness', 'AI coding assistant' (-> unspecified). A vendor's AI "
    "security research team is an AI tool: 'OpenAI Codex Security', 'in collaboration with Claude "
    "and Anthropic Research', 'Calif.io in collaboration with Claude'. So is a vendor's AI "
    "vulnerability-analysis platform such as Xint Code (-> other); credited in Reported-by, it is "
    "ai_found. A human hacking team or contest ('Team X as part of zeroday.cloud'), a fuzzer, "
    "Coverity, clang-tidy or another linter, a static analyzer, a bot "
    "account, a database cursor, a planner or cost model, an authentication agent, or generated "
    "columns are NOT AI tools.\n"
    "\n"
    "ROLES. The four work roles are independent -- set EVERY one the text supports; two or three "
    "at once is common ('Opus looked for bugs and wrote the test' = ai_found + ai_authored). "
    "Casual phrasing counts as much as a formal credit: 'I asked Claude', 'AI tells me', 'Gemini "
    "told me', 'I fed it into ChatGPT', 'asked some LLMs about this' are all real uses of the AI. "
    "ai_found: the AI, or a script/harness the AI wrote, discovered or reported the defect "
    "(Reported-by naming an AI or an AI security team; 'Claude Code found this'; 'found using a "
    "fuzz script I asked Claude Code to write'; 'my claude feature-crosscheck analysis found'). "
    "ai_analyzed: the human already had the problem or a patch and used the AI to understand, "
    "diagnose, review, cross-check or verify it, or to explain the code ('AI tells me this needs an "
    "xid', 'I asked some LLMs about this', 'Gemini told me HMAC_Init_ex was retrofitted', 'I fed "
    "your version into Chat-GPT', 'Claude wrote the analysis'). ai_authored: the AI wrote or drafted "
    "something that is part of the submission -- the patch, a prototype, a test, a demo patch, a "
    "reproducer that is attached, or the report text ('the code is almost entirely generated by AI "
    "harness', 'the attached test patch, written by Claude Code', 'I had Opus write the demo', 'I "
    "used an AI coding assistant while preparing this'). ai_tooling: the AI produced a side "
    "artifact used during the work but not submitted as the change -- a benchmark script, a "
    "measurement script, reproduction steps, a webpage or diagram, a findings report, 'AI-assisted "
    "validations', an AI's quoted opinion pasted for reference ('here is what Chat-GPT had to "
    "say'). mentioned_only: an AI is referred to but did nothing for THIS work -- a proposal to use "
    "AI in the future, an LLM-generated workload that triggered the bug, a feature for AI clients, "
    "an AI policy debate, a URL tracking parameter, a joke. It is exclusive with the work roles. A "
    "text with no AI reference at all gets every flag false.\n"
    "\n"
    "disclosure_form: 'trailer' when the AI appears in a Key: value credit line (Reported-by:, "
    "Author:, Analyzed-by:, Co-authored-by:, Assisted-by:); 'prose' for a sentence in the body; "
    "'disclaimer' when the author distances themselves from AI-written content rather than "
    "crediting it ('the submitted code was clearly AI-generated, I cleaned it up', 'fully "
    "AI-generated, I have not looked at it'); 'none' when there is no AI reference. vendor is "
    "'none' only when there is no AI reference at all (a mentioned_only text still names its "
    "vendor).\n"
    "\n"
    "ANSWER IN THIS ORDER. ai_mentions: quote EVERY phrase in the text that names or refers to an "
    "AI tool, scanning the whole text including trailers and postscripts, separated by ' / ', or "
    "'none'. Then for each work role in turn -- found_evidence then ai_found, analyzed_evidence "
    "then ai_analyzed, authored_evidence then ai_authored, tooling_evidence then ai_tooling -- "
    "quote the phrase (under 20 words) that supports THAT role, or 'none', and set the flag "
    "accordingly; judge each role on its own, several can be true. Then mentioned_only, vendor, "
    "disclosure_form, and a confidence in [0, 1]."
)


# The JSON object the model must answer with: classify_ai_one sends
# AiAnswer.model_json_schema() to Ollama as the schema, and parse_ai_label
# validates the reply against it. Besides the label fields, the model fills
# free-text fields on the way: ai_mentions and each work role's evidence.
# Field order is the chain of thought: the constrained decoder first lists
# every AI mention (so a casual one deep in a long message is not skipped),
# then for EACH work role quotes its evidence (or 'none') before setting the
# flag -- roles are decided one at a time, so a multi-role text is not
# collapsed to its most obvious role. Changing a field changes the schema:
# bump AI_PROMPT_VERSION. (Comments, not a docstring: pydantic would send a
# docstring to Ollama as the schema's description.)
class AiAnswer(BaseModel):
    ai_mentions: str
    found_evidence: str
    ai_found: bool
    analyzed_evidence: str
    ai_analyzed: bool
    authored_evidence: str
    ai_authored: bool
    tooling_evidence: str
    ai_tooling: bool
    mentioned_only: bool
    vendor: Vendor
    disclosure_form: DisclosureForm
    confidence: float


class AiLabel(NamedTuple):
    ai_found: bool
    ai_analyzed: bool
    ai_authored: bool
    ai_tooling: bool
    mentioned_only: bool
    vendor: str
    disclosure_form: str
    confidence: float
    rationale: str


def ai_content_hash(text: str, model: str) -> str:
    """Stable identity for a (text, model, prompt) triple -- the re-inference key."""
    return content_hash(text, model, AI_PROMPT_VERSION)


def roles_prompt(rows: Iterable[tuple[int, str, str]]) -> str:
    """The numbered-definitions prompt block from ai_involvement_roles rows of
    (role_order, role, definition), ordered by role_order."""
    ordered = sorted(rows, key=lambda r: r[0])
    return "\n".join(f"{order}. {role} — {definition}" for order, role, definition in ordered)


def parse_ai_label(content: dict[str, Any]) -> AiLabel:
    """A model answer -> AiLabel. The answer is validated against AiAnswer
    first: a missing field, a wrong type or an out-of-enum vendor or disclosure
    form raises pydantic's ValidationError (a ValueError, so chat_json
    retries). A work role wins over mentioned_only: the model sometimes sets
    both, and the roles carry the evidence. The rationale is the mention list
    plus each set role's evidence."""
    answer = AiAnswer.model_validate(content)
    roles = {
        "found": (answer.ai_found, answer.found_evidence),
        "analyzed": (answer.ai_analyzed, answer.analyzed_evidence),
        "authored": (answer.ai_authored, answer.authored_evidence),
        "tooling": (answer.ai_tooling, answer.tooling_evidence),
    }
    any_role = any(on for on, _ in roles.values())
    parts = [f"mentions: {squash_whitespace(answer.ai_mentions)}"]
    parts.extend(f"{role}: {squash_whitespace(evidence)}" for role, (on, evidence) in roles.items() if on)
    return AiLabel(
        ai_found=answer.ai_found,
        ai_analyzed=answer.ai_analyzed,
        ai_authored=answer.ai_authored,
        ai_tooling=answer.ai_tooling,
        mentioned_only=answer.mentioned_only and not any_role,
        vendor=answer.vendor,
        disclosure_form=answer.disclosure_form,
        confidence=clamp_confidence(answer.confidence),
        rationale=" | ".join(parts),
    )


def hint_lines(text: str) -> list[str]:
    """The lines of `text` containing an AI-related word, for the prompt's
    mention hint. A small model reading a long message skips a casual mention
    ('benchmark script generated by LLM' three screens down); pointing at the
    lines fixes recall. It is a HINT, not a filter: the model still reads the
    whole text, and a hinted line with an ordinary meaning is judged by it."""
    lines = [" ".join(line.split()) for line in text.splitlines() if HINT_NET.search(line)]
    return [line[:HINT_LINE_CHARS] for line in lines[:HINT_MAX_LINES]]


def classify_ai_one(text: str, model: str, prompt_block: str) -> AiLabel:
    """One Ollama call -> an AiLabel."""
    hints = hint_lines(text)
    hint_block = (
        "\n\nLines containing an AI-related word (a hint for ai_mentions; the full artifact above is what you judge):\n"
        + "\n".join(f"- {line}" for line in hints)
        if hints
        else ""
    )
    user = f'Roles:\n{prompt_block}\n\nArtifact:\n"""\n{text}\n"""{hint_block}'
    return chat_json(SYSTEM_PROMPT, user, model, AiAnswer.model_json_schema(), parse_ai_label)


def label_to_cells(label: AiLabel) -> list[str]:
    """An AiLabel as the CSV cells for LABEL_COLS[3:] (flags, vendor, form, confidence, rationale)."""
    return [
        *[str(flag).lower() for flag in label[:5]],
        label.vendor,
        label.disclosure_form,
        f"{label.confidence:.2f}",
        label.rationale,
    ]


def as_bool(value: Any) -> bool:
    """A CSV/DuckDB boolean cell (True, 'true', 'True') -> bool."""
    return value is True or str(value).strip().lower() == "true"


Classifier = Callable[[str], AiLabel]


# the model output = LABEL_COLS + is_classified: false for a text that was
# neither cached nor classifiable (Ollama or the model absent -> cached-only
# mode). Such rows carry NULL labels and are never written to the cache CSV.
OUTPUT_COLS = (*LABEL_COLS, "is_classified")
UNCLASSIFIED_CELLS = [None] * (len(LABEL_COLS) - 3)  # everything after content_hash, model, prompt_version


def label_rows(
    items: Iterable[tuple[Sequence[str], str]],
    cache: Mapping[str, Sequence[Any]],
    model: str,
    classify: Classifier | None,
    max_inline: int | None = None,
    on_progress: Callable[[int, int], None] | None = None,
) -> list[list[Any]]:
    """Label every (key cells, text) item: from `cache` (content_hash -> the
    LABEL_COLS cells) when the text was seen before, else by calling `classify`.
    Returns rows of key cells + OUTPUT_COLS cells. `classify` None is cached-only
    mode (Ollama unavailable): unseen texts get NULL labels and is_classified
    false instead of failing the build. `max_inline` caps how many fresh
    classifications a caller (a dbt build) is willing to run inline -- exceeding
    it raises so a bulk change goes through the resumable backfill instead of a
    many-hour build."""
    rows: list[list[Any]] = []
    todo: list[tuple[Sequence[str], str, str]] = []
    for keys, text in items:
        digest = ai_content_hash(text, model)
        seen = cache.get(digest)
        if seen is not None:
            rows.append([*keys, *[str(cell) for cell in seen], True])
        else:
            todo.append((keys, text, digest))
    if classify is None:
        rows.extend([*keys, digest, model, AI_PROMPT_VERSION, *UNCLASSIFIED_CELLS, False] for keys, _, digest in todo)
        return rows
    if max_inline is not None and len(todo) > max_inline:
        msg = (
            f"{len(todo)} texts need AI-involvement classification, more than the {max_inline} a build "
            "classifies inline: run backfill_ai_involvement.py (resumable) first"
        )
        raise RuntimeError(msg)
    for done, (keys, text, digest) in enumerate(todo, start=1):
        label = classify(text)
        rows.append([*keys, digest, model, AI_PROMPT_VERSION, *label_to_cells(label), True])
        if on_progress is not None:
            on_progress(done, len(todo))
    return rows
