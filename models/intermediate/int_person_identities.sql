-- Every occurrence of a person acting in a role: git patch authors and git
-- committers (from int_git_commits, which resolves the real patch author from
-- the body's "Author:" trailer), mailing-list senders (from stg_list_messages),
-- and the real bug reporters (from int_bug_reports, parsed from the form
-- body). One row per occurrence. node_id is the (email, name) identity node
-- from the person_node() macro; int_person_map groups those nodes into people
-- (shared email OR name) and the facts compute the same node_id to join. The
-- pgsql-bugs web form (noreply@postgresql.org) stays as a list_sender here
-- (it IS the transport sender); the real person is the bug_reporter identity.
WITH git_authors AS (
  SELECT
    patch_author_email AS person_email,
    patch_author_name AS person_name,
    'git_author' AS identity_role,
    'git' AS source_list,
    commit_ts AS seen_ts,
    commit_dt AS seen_dt
  FROM {{ ref('int_git_commits') }}
),

git_committers AS (
  SELECT
    committer_email AS person_email,
    committer_name AS person_name,
    'git_committer' AS identity_role,
    'git' AS source_list,
    commit_ts AS seen_ts,
    commit_dt AS seen_dt
  FROM {{ ref('int_git_commits') }}
),

list_senders AS (
  SELECT
    author_email AS person_email,
    author_name AS person_name,
    'list_sender' AS identity_role,
    list_name AS source_list,
    sent_ts AS seen_ts,
    sent_dt AS seen_dt
  FROM {{ ref('int_message_threads') }}
),

bug_reporters AS (
  SELECT
    reporter_email AS person_email,
    reporter_name AS person_name,
    'bug_reporter' AS identity_role,
    'pgsql-bugs' AS source_list,
    reported_ts AS seen_ts,
    reported_dt AS seen_dt
  FROM {{ ref('int_bug_reports') }}
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
  {{ person_node('person_email', 'person_name') }} AS node_id,
  person_email,
  person_name,
  LOWER(TRIM(COALESCE(person_email, ''))) AS norm_email,
  LOWER(TRIM(COALESCE(person_name, ''))) AS norm_name,
  identity_role,
  source_list,
  seen_ts,
  seen_dt
FROM occurrences
