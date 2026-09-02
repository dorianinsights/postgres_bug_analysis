-- One representative item per distinct fix (the group's first item in file
-- order): its text, CVEs, and keys. Category-free on purpose — the content
-- category and the security-hardening / performance flags are assigned
-- downstream by int_fix_content_categories (the LLM model reads this, so this
-- must not read it back), and fct_fixes joins them on.
WITH group_ids AS (
  SELECT DISTINCT group_ord
  FROM {{ ref('int_fix_groups') }}
)

SELECT itm.*
FROM {{ ref('int_fix_items') }} AS itm
INNER JOIN group_ids AS grp ON itm.item_ord = grp.group_ord
