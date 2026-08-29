{{ config(materialized='external', location='../data/derived/category_vs_subsystem.csv', format='csv') }}

-- Agreement matrix: keyword category (from the release-note text) x
-- dominant subsystem (from the changed file paths), over fixes whose
-- annotated commits matched the corpus.
SELECT
  category,
  dominant_subsystem,
  COUNT(*) AS n_fixes
FROM {{ ref('int_fix_changes') }}
WHERE dominant_subsystem IS NOT null
GROUP BY category, dominant_subsystem
ORDER BY category ASC, n_fixes DESC, dominant_subsystem ASC
