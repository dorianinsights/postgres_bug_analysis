-- The Phase-1 headline: a confusion matrix of the regex vs LLM content
-- categories over non-CVE fixes (CVE fixes carry the metadata "Security (CVE)"
-- label, not a comparable content judgment). One row per (regex category, LLM
-- category) with the fix count; the diagonal (agrees) is agreement. Small and
-- diffable -- it earns a data/derived twin, unlike the per-fix audit.
SELECT
  reps.category AS category_regex,
  llm.category_llm,
  reps.category = llm.category_llm AS agrees,
  COUNT(*)::BIGINT AS fix_cnt
FROM {{ ref('int_fix_reps') }} AS reps
INNER JOIN {{ ref('stg_fix_categories_llm') }} AS llm
  ON reps.item_ord = llm.item_ord
WHERE reps.cves IS null
GROUP BY ALL
