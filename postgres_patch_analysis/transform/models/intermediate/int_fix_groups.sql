-- Cross-branch dedup: connected components over the items of each wave.
-- Two items are the same fix when EITHER their text_key or their hash_key
-- matches, transitively. Both signals are constants the notes author copies
-- verbatim between branch files, and each covers the other's blind spot,
-- all observed in real waves:
--
-- - Same fix, wording drifted between branches -> caught by the hash set.
-- - Same fix, one branch's block carries an extra follow-up commit
--   (to_date() localized-names, Aug 2026) -> caught by the text.
-- - Different fixes sharing a combined backpatch commit (to_char overrun +
--   standby reconnect, Aug 2026) -> mere hash OVERLAP would over-merge;
--   requiring the identical full set keeps them apart.
-- - Branch-scope variants documented as separate items with subset blocks
--   (pg_dump sort order, Nov 2025) -> neither signal matches; stay apart.
--
-- The recursive walk computes full reachability, so the grouping is
-- genuinely transitive (build_datasets.py's single greedy pass was not:
-- an item bridging two already-seen groups did not merge them).
-- group_ord = the component's lowest item_ord = its representative item.
WITH RECURSIVE item_keys AS (
  SELECT
    item_ord,
    wave_date,
    text_key AS join_key
  FROM {{ ref('int_fix_items') }}
  UNION ALL
  SELECT
    item_ord,
    wave_date,
    hash_key AS join_key
  FROM {{ ref('int_fix_items') }}
  WHERE hash_key IS NOT null
),

edges AS (
  SELECT DISTINCT
    lhs.item_ord AS src_ord,
    rhs.item_ord AS dst_ord
  FROM item_keys AS lhs
  INNER JOIN item_keys AS rhs
    ON lhs.wave_date = rhs.wave_date AND lhs.join_key = rhs.join_key
  WHERE lhs.item_ord != rhs.item_ord
),

reachable (item_ord, peer_ord) AS (
  SELECT
    item_ord,
    item_ord AS peer_ord
  FROM {{ ref('int_fix_items') }}
  UNION
  SELECT
    rch.item_ord,
    edg.dst_ord AS peer_ord
  FROM reachable AS rch
  INNER JOIN edges AS edg ON rch.peer_ord = edg.src_ord
)

SELECT
  item_ord,
  MIN(peer_ord) AS group_ord
FROM reachable
GROUP BY item_ord
