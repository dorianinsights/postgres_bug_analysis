-- Every occurrence of a person acting in a role: git patch authors and git
-- committers (from int_git_commits, which resolves the real patch author from
-- the body's "Author:" trailer), mailing-list senders (from stg_list_messages,
-- excluding the pgsql-bugs web form's generic From address), and the real bug
-- reporters (from int_bug_reporters, parsed from the form body). One row per
-- occurrence; dim_person rolls these up to one row per person. person_key is
-- derived here via the shared person_key() macro so it matches the key the
-- facts compute from their own email/name columns — the star joins on it.
WITH git_authors AS (
  SELECT
    patch_author_email AS person_email,
    patch_author_name AS person_name,
    'git_author' AS identity_role,
    'git' AS source_list,
    commit_ts AS seen_ts
  FROM {{ ref('int_git_commits') }}
),

git_committers AS (
  SELECT
    committer_email AS person_email,
    committer_name AS person_name,
    'git_committer' AS identity_role,
    'git' AS source_list,
    commit_ts AS seen_ts
  FROM {{ ref('int_git_commits') }}
),

list_senders AS (
  SELECT
    author_email AS person_email,
    author_name AS person_name,
    'list_sender' AS identity_role,
    list_name AS source_list,
    sent_ts AS seen_ts
  FROM {{ ref('stg_list_messages') }}
  -- drop the pgsql-bugs web form itself — the real senders of form reports
  -- come in as bug_reporter identities below
  WHERE NOT (list_name = 'pgsql-bugs' AND author_email = 'noreply@postgresql.org')
),

bug_reporters AS (
  SELECT
    reporter_email AS person_email,
    reporter_name AS person_name,
    'bug_reporter' AS identity_role,
    'pgsql-bugs' AS source_list,
    reported_ts AS seen_ts
  FROM {{ ref('int_bug_reporters') }}
),

occurrences AS (
  SELECT * FROM git_authors
  UNION ALL
  SELECT * FROM git_committers
  UNION ALL
  SELECT * FROM list_senders
  UNION ALL
  SELECT * FROM bug_reporters
)

SELECT
  {{ person_key('person_email', 'person_name') }} AS person_key,
  person_email,
  person_name,
  identity_role,
  source_list,
  seen_ts
FROM occurrences
