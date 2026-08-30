-- The person/entity dimension: one row per distinct person across the whole
-- pipeline, whether they show up as a git patch author, a git committer, or a
-- mailing-list sender (the roles are booleans, not separate rows — the same
-- human plays several). First-pass identity is the normalized email, with a
-- normalized-name fallback for message senders who gave no address; a curated
-- alias seed for people who use several emails is a documented later
-- refinement. Grain = person_key. -> ../data/derived/dim_person.csv
WITH per_key AS (
  SELECT
    person_key,
    MAX(LOWER(TRIM(person_email))) AS canonical_email,
    BOOL_OR(identity_role = 'git_author') AS is_git_author,
    BOOL_OR(identity_role = 'git_committer') AS is_git_committer,
    BOOL_OR(identity_role = 'list_sender') AS is_list_sender,
    MIN((seen_ts AT TIME ZONE 'utc')::DATE) AS first_seen_dt,
    MAX((seen_ts AT TIME ZONE 'utc')::DATE) AS last_seen_dt,
    COUNT(DISTINCT source_list)::BIGINT AS source_list_cnt
  FROM {{ ref('int_person_identities') }}
  GROUP BY ALL
),

-- canonical display name = the person's most frequently used name spelling
name_votes AS (
  SELECT
    person_key,
    person_name
  FROM {{ ref('int_person_identities') }}
  WHERE person_name IS NOT null
  -- explicit GROUP BY (not GROUP BY ALL): DuckDB can't combine GROUP BY ALL
  -- with QUALIFY, and the tie-break counts occurrences per (key, name)
  GROUP BY person_key, person_name
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY person_key ORDER BY COUNT(*) DESC, person_name ASC
  ) = 1
)

SELECT
  pky.person_key,
  pky.canonical_email,
  COALESCE(nvt.person_name, pky.canonical_email, '(unknown)') AS canonical_name,
  pky.is_git_author,
  pky.is_git_committer,
  pky.is_list_sender,
  pky.first_seen_dt,
  pky.last_seen_dt,
  pky.source_list_cnt
FROM per_key AS pky
LEFT JOIN name_votes AS nvt ON pky.person_key = nvt.person_key
