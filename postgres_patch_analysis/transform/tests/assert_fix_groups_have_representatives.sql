-- Connected-components sanity: every group id must itself be a member of
-- the group it names (group_ord = the component's minimum item_ord, and the
-- minimum is always in the set).
WITH group_ids AS (
  SELECT DISTINCT group_ord
  FROM {{ ref('int_fix_groups') }}
)

SELECT gid.group_ord
FROM group_ids AS gid
LEFT JOIN {{ ref('int_fix_groups') }} AS grp
  ON gid.group_ord = grp.item_ord AND gid.group_ord = grp.group_ord
WHERE grp.item_ord IS null
