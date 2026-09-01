-- Per-fix audit: the regex classifier (category_rules, applied in int_fix_reps)
-- vs the local-LLM classifier (classify_fixes.py). One row per distinct fix that
-- has been classified (INNER JOIN the LLM cache -- a partial classify run audits
-- only what it covered). is_cve marks fixes the regex labels "Security (CVE)"
-- from metadata; for those the regex has no content judgment to compare, so
-- agrees is defined only for non-CVE fixes (NULL otherwise).
SELECT
  reps.item_ord,
  reps.release_dt,
  reps.summary,
  reps.category AS category_regex,
  llm.category_llm,
  llm.confidence,
  llm.rationale,
  reps.cves IS NOT null AS is_cve,
  CASE WHEN reps.cves IS null THEN reps.category = llm.category_llm END AS agrees
FROM {{ ref('int_fix_reps') }} AS reps
INNER JOIN {{ ref('stg_fix_categories_llm') }} AS llm
  ON reps.item_ord = llm.item_ord
