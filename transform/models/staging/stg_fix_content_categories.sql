-- One content-taxonomy label per distinct fix, typed from the offline
-- classify_content.py cache. item_ord is the fix grain. category_content is one
-- of the 12 content categories (content_categories seed); is_security_hardening
-- and is_performance are orthogonal flags the LLM sets independently of the
-- category. confidence is an exact two-decimal soft score. content_hash / model
-- / prompt_version are the cache provenance.
SELECT
  cc.item_ord,
  cc.content_hash,
  cc.model,
  cc.prompt_version,
  cc.category_content,
  cc.confidence::DECIMAL(3, 2) AS confidence,
  cc.is_security_hardening = 'true' AS is_security_hardening,
  cc.is_performance = 'true' AS is_performance,
  cc.rationale
FROM {{ source('inferred', 'fix_content_categories') }} AS cc
