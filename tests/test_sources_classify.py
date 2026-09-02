# pyright: strict
"""sources.classify: the pure helpers behind the incremental classifier model
(the Ollama call itself, classify_one, is network I/O and isn't unit-tested here).
"""

from sources.classify import build_schema, content_hash, taxonomy_prompt


def test_content_hash_is_stable_and_16_hex() -> None:
    digest = content_hash("Fix a crash in WAL replay", "qwen3:30b-a3b")
    assert digest == content_hash("Fix a crash in WAL replay", "qwen3:30b-a3b")  # deterministic
    assert len(digest) == 16
    assert all(c in "0123456789abcdef" for c in digest)


def test_content_hash_changes_with_text_and_model() -> None:
    base = content_hash("text one", "modelA")
    assert content_hash("text two", "modelA") != base  # text change re-triggers
    assert content_hash("text one", "modelB") != base  # model change re-triggers


def test_taxonomy_prompt_orders_by_category_order() -> None:
    rows = [(2, "Beta", "the second"), (1, "Alpha", "the first"), (3, "Gamma", "the third")]
    names, block = taxonomy_prompt(rows)
    assert names == ["Alpha", "Beta", "Gamma"]
    assert block == "1. Alpha — the first\n2. Beta — the second\n3. Gamma — the third"


def test_build_schema_reasons_before_category_and_pins_the_enum() -> None:
    names = ["Alpha", "Beta"]
    schema = build_schema(names)
    assert schema["type"] == "object"
    # reasoning must come first so the constrained decoder thinks before choosing
    assert list(schema["properties"].keys())[0] == "reasoning"
    assert schema["required"][0] == "reasoning"
    assert schema["properties"]["category"]["enum"] == names
    assert set(schema["required"]) == {"reasoning", "category", "is_security_hardening", "is_performance", "confidence"}
