-- (commit_hash, message_id) from the Discussion: trailers in commit
-- message bodies — the project's ground-truth link from fixes back to
-- mailing-list threads. Both URL spellings occur (postgr.es/m/ and
-- postgresql.org/message-id/). Hrefs in trailers are sometimes
-- percent-encoded; ids are decoded to the canonical form, but only when
-- every % begins a valid escape (URL_DECODE raises otherwise).
WITH refs AS (
  SELECT
    commit_hash,
    UNNEST(REGEXP_EXTRACT_ALL(body, 'postgr\.es/m/([^\s>,)\]]+)', 1)) AS raw_ref
  FROM {{ ref('int_git_commits') }}
  WHERE body IS NOT null
  UNION ALL
  SELECT
    commit_hash,
    UNNEST(REGEXP_EXTRACT_ALL(body, 'postgresql\.org/message-id/(?:flat/)?([^\s>,)\]]+)', 1)) AS raw_ref
  FROM {{ ref('int_git_commits') }}
  WHERE body IS NOT null
)

SELECT DISTINCT
  commit_hash,
  CASE
    WHEN REGEXP_MATCHES(REGEXP_REPLACE(raw_ref, '%[0-9A-Fa-f]{2}', '', 'g'), '%') THEN raw_ref
    ELSE URL_DECODE(raw_ref)
  END AS message_id
FROM refs
