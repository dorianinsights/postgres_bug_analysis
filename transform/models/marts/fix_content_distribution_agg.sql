-- Distribution of the new content taxonomy over classified fixes: one row per
-- category with its fix count and how many carry each orthogonal flag. Small and
-- diffable (a data/derived twin) -- the headline for validating the taxonomy
-- against the old regex categories (whose catch-all "Other functionality" held
-- 29% of fixes; a healthy taxonomy spreads those out).
SELECT
  cls.category_content,
  COUNT(*)::BIGINT AS fix_cnt,
  COUNT(*) FILTER (WHERE cls.is_cve)::BIGINT AS cve_cnt,
  COUNT(*) FILTER (WHERE cls.is_security_hardening)::BIGINT AS security_hardening_cnt,
  COUNT(*) FILTER (WHERE cls.is_performance)::BIGINT AS performance_cnt,
  ROUND(AVG(cls.confidence), 3) AS avg_confidence
FROM {{ ref('fix_content_classification') }} AS cls
GROUP BY ALL
