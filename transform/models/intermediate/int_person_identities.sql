-- Every occurrence of a person acting in a role: git patch authors and git
-- committers (from stg_git_commits) and mailing-list senders (from
-- stg_list_messages), one row per occurrence. The raw material dim_person
-- rolls up to one row per person. person_key is derived here via the shared
-- person_key() macro so it matches the key the facts compute from their own
-- email/name columns — the star joins on it.
WITH git_authors AS (
  SELECT
    author_email AS person_email,
    author_name AS person_name,
    'git_author' AS identity_role,
    'git' AS source_list,
    commit_ts AS seen_ts
  FROM {{ ref('stg_git_commits') }}
),

git_committers AS (
  SELECT
    committer_email AS person_email,
    committer_name AS person_name,
    'git_committer' AS identity_role,
    'git' AS source_list,
    commit_ts AS seen_ts
  FROM {{ ref('stg_git_commits') }}
),

list_senders AS (
  SELECT
    author_email AS person_email,
    author_name AS person_name,
    'list_sender' AS identity_role,
    list_name AS source_list,
    sent_ts AS seen_ts
  FROM {{ ref('stg_list_messages') }}
),

occurrences AS (
  SELECT * FROM git_authors
  UNION ALL
  SELECT * FROM git_committers
  UNION ALL
  SELECT * FROM list_senders
)

SELECT
  {{ person_key('person_email', 'person_name') }} AS person_key,
  person_email,
  person_name,
  identity_role,
  source_list,
  seen_ts
FROM occurrences
