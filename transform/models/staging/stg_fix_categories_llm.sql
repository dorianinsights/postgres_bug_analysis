-- One LLM content-category label per distinct fix, typed from the offline
-- classify_fixes.py cache. item_ord is the fix grain (joins int_fix_reps /
-- fct_fixes). confidence is an exact two-decimal soft score (DECIMAL(3,2)) --
-- an LLM-emitted estimate, but stored exactly, not as a float measurement.
-- category_llm is one of the nine CONTENT categories (the regex "Security
-- (CVE)" label is metadata, excluded from the model's choices).
-- content_hash / model / prompt_version are the cache provenance.
SELECT
  llm.item_ord,
  llm.content_hash,
  llm.model,
  llm.prompt_version,
  llm.category_llm,
  llm.confidence::DECIMAL(3, 2) AS confidence,
  llm.rationale
FROM {{ source('inferred', 'fix_categories_llm') }} AS llm
