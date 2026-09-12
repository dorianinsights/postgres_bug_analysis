-- Two items are the same fix when EITHER their text_key or their hash_key
-- matches within a release, transitively: a mere hash OVERLAP would over-merge
-- different fixes sharing a combined backpatch commit, so the identical full
-- hash set is the key.
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
