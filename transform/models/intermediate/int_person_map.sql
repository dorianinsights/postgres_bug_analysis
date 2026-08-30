-- Identity resolution: group the (email, name) nodes from int_person_identities
-- into people via connected components — two nodes are the same person when
-- they share a normalized email OR a normalized name, transitively (the same
-- recursive-CTE approach int_fix_groups uses for cross-branch fix dedup). This
-- merges the multi-email split (a committer authoring under a personal address,
-- e.g. Fujii Masao's @postgresql.org committer identity and his gmail Author:
-- trailer). Empty keys form no edges. person_key = the component's lowest
-- node_id. Grain = node_id; the map is node_id -> person_key.
WITH RECURSIVE node_keys AS (
  SELECT DISTINCT
    node_id,
    'e:' || norm_email AS join_key
  FROM {{ ref('int_person_identities') }}
  WHERE norm_email != ''
  UNION
  SELECT DISTINCT
    node_id,
    'n:' || norm_name AS join_key
  FROM {{ ref('int_person_identities') }}
  WHERE norm_name != ''
),

edges AS (
  SELECT DISTINCT
    lhs.node_id AS src_id,
    rhs.node_id AS dst_id
  FROM node_keys AS lhs
  INNER JOIN node_keys AS rhs ON lhs.join_key = rhs.join_key
  WHERE lhs.node_id != rhs.node_id
),

reachable (node_id, peer_id) AS (
  SELECT DISTINCT
    node_id,
    node_id AS peer_id
  FROM node_keys
  UNION
  SELECT
    rch.node_id,
    edg.dst_id AS peer_id
  FROM reachable AS rch
  INNER JOIN edges AS edg ON rch.peer_id = edg.src_id
)

SELECT
  node_id,
  MIN(peer_id) AS person_key
FROM reachable
GROUP BY ALL
