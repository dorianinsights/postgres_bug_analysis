-- One representative item per distinct fix (the group's first item in file
-- order), categorized. Category precedence (formerly categorize.py):
-- any CVE -> "Security (CVE)"; else the lowest-match_order rule whose
-- pattern matches the full text; else "Other functionality".
WITH group_ids AS (
  SELECT DISTINCT group_ord
  FROM {{ ref('int_fix_groups') }}
),

reps AS (
  SELECT itm.*
  FROM {{ ref('int_fix_items') }} AS itm
  INNER JOIN group_ids AS grp ON itm.item_ord = grp.group_ord
),

first_matches AS (
  SELECT
    reps.item_ord,
    MIN(rules.match_order) AS match_order
  FROM reps
  INNER JOIN {{ ref('category_rules') }} AS rules
    ON REGEXP_MATCHES(reps.full_text, rules.pattern, 'i')
  GROUP BY ALL
)

SELECT
  reps.*,
  CASE
    WHEN reps.cves IS NOT null THEN 'Security (CVE)'
    ELSE COALESCE(rules.category, 'Other functionality')
  END AS category
FROM reps
LEFT JOIN first_matches AS fmt ON reps.item_ord = fmt.item_ord
LEFT JOIN {{ ref('category_rules') }} AS rules ON fmt.match_order = rules.match_order
