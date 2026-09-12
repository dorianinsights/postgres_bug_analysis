-- two nodes are the same person when they share a normalized email OR name,
-- transitively; empty keys form no edges
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

{{ connected_components('node_keys', 'node_id', 'person_key') }}
