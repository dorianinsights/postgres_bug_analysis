WITH refs AS (
  SELECT
    commit_hash,
    -- both URL spellings of a message-id link
    UNNEST(
      REGEXP_EXTRACT_ALL(body, 'postgr\.es/m/([^\s>,)\]]+)', 1)
      || REGEXP_EXTRACT_ALL(body, 'postgresql\.org/message-id/(?:flat/)?([^\s>,)\]]+)', 1)
    ) AS raw_ref
  FROM {{ ref('int_git_commits') }}
  WHERE body IS NOT null
),

links AS (
  SELECT DISTINCT
    commit_hash,
    -- decode percent-escapes only when every % starts a valid one (URL_DECODE raises otherwise)
    CASE
      WHEN REGEXP_MATCHES(REGEXP_REPLACE(raw_ref, '%[0-9A-Fa-f]{2}', '', 'g'), '%') THEN raw_ref
      ELSE URL_DECODE(raw_ref)
    END AS message_id
  FROM refs
)

SELECT
  lnk.commit_hash,
  lnk.message_id,
  -- pgsql-bugs wins a cross-post: citing a BUG thread means the work traces to a filed report
  CASE
    WHEN BOOL_OR(msg.list_name = 'pgsql-bugs') THEN 'pgsql-bugs'
    ELSE MIN(msg.list_name)
  END AS source_list
FROM links AS lnk
LEFT OUTER JOIN {{ ref('stg_list_messages') }} AS msg ON lnk.message_id = msg.message_id
GROUP BY lnk.commit_hash, lnk.message_id
