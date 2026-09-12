SELECT
  branch,
  commit_hash,
  commit_ts,
  commit_dt,
  subject,
  body,
  committer_name,
  committer_email,
  -- the body's "Author: Name <email>" trailer; NULL when the committer wrote the patch
  NULLIF(TRIM(REGEXP_EXTRACT(body, 'Author:\s*([^<\n]+?)\s*<([^>\n]+)>', 1)), '') AS body_author_name,
  NULLIF(TRIM(REGEXP_EXTRACT(body, 'Author:\s*([^<\n]+?)\s*<([^>\n]+)>', 2)), '') AS body_author_email,
  COALESCE(body_author_name, committer_name) AS patch_author_name,
  COALESCE(body_author_email, committer_email) AS patch_author_email,
  LOWER(TRIM(REGEXP_REPLACE(subject, '\s+', ' ', 'g'))) AS fix_key,
  REGEXP_MATCHES(
    subject,
    '^(stamp |translation updates|(first-draft |second-draft |last-minute updates for )?release notes'
    || '|docs?: .*release notes|update time zone data|update copyright|re-?pgindent|bump catversion)',
    'i'
  ) AS is_housekeeping,
  -- "Bug: #17434" trailers and prose "bug #17434" alike
  NULLIF(
    LIST_SORT(
      LIST_DISTINCT(
        LIST_TRANSFORM(
          REGEXP_EXTRACT_ALL(body, '[Bb]ug:? #(\d+)', 1),
          num -> num::INTEGER
        )
      )
    ),
    []
  ) AS bug_refs,
  -- Discussion: trailers in both URL spellings, decoded to the bare message id;
  -- percent-escapes are decoded only when every % starts a valid one (URL_DECODE raises otherwise)
  NULLIF(
    LIST_SORT(
      LIST_DISTINCT(
        LIST_TRANSFORM(
          REGEXP_EXTRACT_ALL(body, 'postgr\.es/m/([^\s>,)\]]+)', 1)
          || REGEXP_EXTRACT_ALL(body, 'postgresql\.org/message-id/(?:flat/)?([^\s>,)\]]+)', 1),
          raw_ref -> CASE
            WHEN REGEXP_MATCHES(REGEXP_REPLACE(raw_ref, '%[0-9A-Fa-f]{2}', '', 'g'), '%') THEN raw_ref
            ELSE URL_DECODE(raw_ref)
          END
        )
      )
    ),
    []
  ) AS discussion_refs
FROM {{ ref('stg_git_commits') }}
