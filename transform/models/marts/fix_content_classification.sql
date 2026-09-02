-- Per-fix content classification (classify_content.py) beside the regex category
-- it will replace — the staged-retirement comparison. One row per distinct fix
-- that has been classified (INNER JOIN the LLM cache). is_cve is metadata (from
-- the fix's CVE list); is_security_hardening / is_performance are the LLM's
-- orthogonal flags. category_regex is carried for the transition audit.
SELECT
  reps.item_ord,
  reps.release_dt,
  reps.summary,
  cls.category_content,
  cls.confidence,
  reps.cves IS NOT null AS is_cve,
  cls.is_security_hardening,
  cls.is_performance,
  reps.category AS category_regex,
  cls.rationale
FROM {{ ref('int_fix_reps') }} AS reps
INNER JOIN {{ ref('stg_fix_content_categories') }} AS cls
  ON reps.item_ord = cls.item_ord
