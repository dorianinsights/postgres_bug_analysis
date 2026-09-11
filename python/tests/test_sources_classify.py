# pyright: strict
"""sources.classify: the pure helpers behind the incremental classifier model
(the Ollama call itself, classify_one, is network I/O and isn't unit-tested here).
"""

from pg_analysis.sources.classify import build_schema, content_hash, installed_models, model_matches, taxonomy_prompt


def test_installed_models_reads_an_api_tags_answer() -> None:
    tags = {"models": [{"name": "qwen3:30b-a3b", "size": 1}, {"model": "gemma4:12b"}, {}]}
    assert installed_models(tags) == ["qwen3:30b-a3b", "gemma4:12b", ""]
    assert installed_models({}) == []


def test_model_matches_is_exact_except_for_an_implied_latest_tag() -> None:
    assert model_matches("qwen3:30b-a3b", "qwen3:30b-a3b")
    assert not model_matches("qwen3:30b", "qwen3:30b-a3b")  # a different tag is a different model
    assert model_matches("llama3.2:latest", "llama3.2")  # a bare name means :latest
    assert not model_matches("llama3.2:1b", "llama3.2")


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
