-- Agreement matrix: keyword category (from the release-note text) x
-- dominant subsystem (from the changed file paths), over fixes whose
-- annotated commits matched the corpus.
SELECT
  category,
  dominant_subsystem,
  COUNT(*) AS fix_cnt
FROM {{ ref('int_fix_changes') }}
WHERE dominant_subsystem IS NOT null
GROUP BY ALL
