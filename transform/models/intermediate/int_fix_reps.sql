-- One representative item per distinct fix (the group's first item in file
-- order), carrying its content category and the orthogonal security-hardening /
-- performance flags from the LLM classifier (classify_content.py, via
-- stg_fix_content_categories). This replaced the category_rules regex classifier
-- once the bottom-up content taxonomy was validated; security is now a flag
-- (is_security_hardening) and a CVE metadata check, not a category.
WITH group_ids AS (
  SELECT DISTINCT group_ord
  FROM {{ ref('int_fix_groups') }}
),

reps AS (
  SELECT itm.*
  FROM {{ ref('int_fix_items') }} AS itm
  INNER JOIN group_ids AS grp ON itm.item_ord = grp.group_ord
)

SELECT
  reps.*,
  cls.category_content AS category,
  cls.is_security_hardening,
  cls.is_performance
FROM reps
LEFT JOIN {{ ref('stg_fix_content_categories') }} AS cls ON reps.item_ord = cls.item_ord
