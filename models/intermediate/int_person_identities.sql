WITH occurrences AS (
  -- a commit yields two occurrences: the real patch author and the committer
  SELECT
    ident.person['email'] AS person_email,
    ident.person['name'] AS person_name,
    ident.person['identity_role'] AS identity_role,
    'git' AS source_list,
    gcm.commit_ts AS seen_ts,
    gcm.commit_dt AS seen_dt
  FROM {{ ref('int_git_commits') }} AS gcm,
    UNNEST([
      { 'email': gcm.patch_author_email, 'name': gcm.patch_author_name, 'identity_role': 'git_author' },
      { 'email': gcm.committer_email, 'name': gcm.committer_name, 'identity_role': 'git_committer' }
    ]) AS ident (person)
  UNION ALL
  SELECT
    author_email AS person_email,
    author_name AS person_name,
    'list_sender' AS identity_role,
    list_name AS source_list,
    sent_ts AS seen_ts,
    sent_dt AS seen_dt
  FROM {{ ref('int_message_threads') }}
  UNION ALL
  SELECT
    reporter_email AS person_email,
    reporter_name AS person_name,
    'bug_reporter' AS identity_role,
    'pgsql-bugs' AS source_list,
    reported_ts AS seen_ts,
    reported_dt AS seen_dt
  FROM {{ ref('int_bug_reports') }}
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
