WITH flagged AS (
  SELECT
    branch,
    commit_hash,
    commit_ts,
    commit_dt,
    subject,
    body,
    committer_name,
    committer_email,
    NULLIF(TRIM(REGEXP_EXTRACT(body, 'Author:\s*([^<\n]+?)\s*<([^>\n]+)>', 1)), '') AS body_author_name,
    NULLIF(TRIM(REGEXP_EXTRACT(body, 'Author:\s*([^<\n]+?)\s*<([^>\n]+)>', 2)), '') AS body_author_email
  FROM {{ ref('stg_git_commits') }}
)

SELECT
  branch,
  commit_hash,
  commit_ts,
  commit_dt,
  subject,
  body,
  committer_name,
  committer_email,
  COALESCE(body_author_name, committer_name) AS patch_author_name,
  COALESCE(body_author_email, committer_email) AS patch_author_email,
  LOWER(TRIM(REGEXP_REPLACE(subject, '\s+', ' ', 'g'))) AS fix_key,
  REGEXP_MATCHES(
    subject,
    '^(stamp |translation updates|(first-draft |second-draft |last-minute updates for )?release notes'
    || '|docs?: .*release notes|update time zone data|update copyright|re-?pgindent|bump catversion)',
    'i'
  ) AS is_housekeeping
FROM flagged
