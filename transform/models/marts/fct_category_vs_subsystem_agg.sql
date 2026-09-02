-- Cross-tab: content category (int_fix_content_categories) x dominant subsystem
-- (from the changed file paths), over fixes with a resolvable subsystem.
SELECT
  category,
  dominant_subsystem,
  COUNT(*) AS fix_cnt
FROM {{ ref('fct_fixes') }}
WHERE dominant_subsystem IS NOT null
GROUP BY ALL
