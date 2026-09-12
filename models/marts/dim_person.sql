{% set columns = [
  'dim_person_key', 'canonical_email', 'canonical_name', 'is_git_author', 'is_git_committer',
  'is_list_sender', 'is_bug_reporter', 'first_seen_dt', 'last_seen_dt', 'source_list_cnt',
  'is_synthetic_row',
] %}

WITH resolved AS (
  SELECT
    pmp.person_key,
    idn.person_email,
    idn.person_name,
    idn.identity_role,
    idn.source_list,
    idn.seen_dt
  FROM {{ ref('int_person_identities') }} AS idn
  INNER JOIN {{ ref('int_person_map') }} AS pmp ON idn.node_id = pmp.node_id
),

per_key AS (
  SELECT
    person_key,
    MAX(LOWER(TRIM(person_email))) AS canonical_email,
    BOOL_OR(identity_role = 'git_author') AS is_git_author,
    BOOL_OR(identity_role = 'git_committer') AS is_git_committer,
    BOOL_OR(identity_role = 'list_sender') AS is_list_sender,
    BOOL_OR(identity_role = 'bug_reporter') AS is_bug_reporter,
    MIN(seen_dt) AS first_seen_dt,
    MAX(seen_dt) AS last_seen_dt,
    COUNT(DISTINCT source_list)::BIGINT AS source_list_cnt
  FROM resolved
  GROUP BY ALL
),

-- canonical display name = the person's most frequently used name spelling
name_votes AS (
  SELECT
    person_key,
    person_name
  FROM resolved
  WHERE person_name IS NOT null
  GROUP BY person_key, person_name
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY person_key ORDER BY COUNT(*) DESC, person_name ASC
  ) = 1
)

SELECT
  pky.person_key AS dim_person_key,
  pky.canonical_email,
  COALESCE(nvt.person_name, pky.canonical_email, '(unknown)') AS canonical_name,
  pky.is_git_author,
  pky.is_git_committer,
  pky.is_list_sender,
  pky.is_bug_reporter,
  pky.first_seen_dt,
  pky.last_seen_dt,
  pky.source_list_cnt,
  false AS is_synthetic_row
FROM per_key AS pky
LEFT JOIN name_votes AS nvt ON pky.person_key = nvt.person_key
{{ special_member_rows(
  'dim_person_key', columns,
  unknown={
    'canonical_name': "'Unknown'", 'is_git_author': 'false', 'is_git_committer': 'false',
    'is_list_sender': 'false', 'is_bug_reporter': 'false', 'first_seen_dt': past_eternity_dt(),
    'last_seen_dt': past_eternity_dt(), 'source_list_cnt': '0::BIGINT',
  },
  not_applicable={
    'canonical_name': "'Not applicable'", 'is_git_author': 'false', 'is_git_committer': 'false',
    'is_list_sender': 'false', 'is_bug_reporter': 'false', 'first_seen_dt': past_eternity_dt(),
    'last_seen_dt': past_eternity_dt(), 'source_list_cnt': '0::BIGINT',
  },
) }}
