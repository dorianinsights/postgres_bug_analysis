WITH RECURSIVE node_keys AS (
  SELECT
    item_ord,
    release_dt::VARCHAR || '|' || text_key AS join_key
  FROM {{ ref('int_fix_items') }}
  UNION ALL
  SELECT
    item_ord,
    release_dt::VARCHAR || '|' || hash_key AS join_key
  FROM {{ ref('int_fix_items') }}
  WHERE hash_key IS NOT null
),

{{ connected_components('node_keys', 'item_ord', 'group_ord') }}
