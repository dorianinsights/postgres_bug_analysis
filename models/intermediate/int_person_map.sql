-- one node per signal; the struct key matches on whichever member is set
-- (struct equality treats NULL members as equal); empty keys form no edges
WITH RECURSIVE node_keys AS (
  SELECT DISTINCT
    node_id,
    { 'email': norm_email, 'name': null::VARCHAR } AS join_key
  FROM {{ ref('int_person_identities') }}
  WHERE norm_email != ''
  UNION
  SELECT DISTINCT
    node_id,
    { 'email': null::VARCHAR, 'name': norm_name } AS join_key
  FROM {{ ref('int_person_identities') }}
  WHERE norm_name != ''
),

{{ connected_components('node_keys', 'node_id', 'person_key') }}
