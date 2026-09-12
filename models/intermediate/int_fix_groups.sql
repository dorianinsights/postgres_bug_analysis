-- one node per signal; the struct key matches within a release on whichever
-- member is set (struct equality treats NULL members as equal)
WITH RECURSIVE node_keys AS (
  SELECT
    item_ord,
    { 'release_dt': release_dt, 'text_key': text_key, 'hash_set': null::VARCHAR[] } AS join_key
  FROM {{ ref('int_fix_items') }}
  UNION ALL
  SELECT
    item_ord,
    { 'release_dt': release_dt, 'text_key': null::VARCHAR, 'hash_set': hash_set } AS join_key
  FROM {{ ref('int_fix_items') }}
  WHERE hash_set IS NOT null
),

{{ connected_components('node_keys', 'item_ord', 'group_ord') }}
