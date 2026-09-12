-- one scalar key per signal; the tags keep a text key from ever matching a hash key
WITH RECURSIVE node_keys AS (
  SELECT
    item_ord,
    release_dt::VARCHAR || '|t:' || text_key AS join_key
  FROM {{ ref('int_fix_items') }}
  UNION ALL
  SELECT
    item_ord,
    release_dt::VARCHAR || '|h:' || hash_set::VARCHAR AS join_key
  FROM {{ ref('int_fix_items') }}
  WHERE hash_set IS NOT null
),

{{ connected_components('node_keys', 'item_ord', 'group_ord') }}
