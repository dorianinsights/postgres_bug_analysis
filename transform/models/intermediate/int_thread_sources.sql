-- One row per distinct archived message id with the list that claims it.
-- Cross-posted messages appear in several archives under the same id;
-- pgsql-bugs wins the tie because a citation of a BUG thread means the
-- work traces back to a filed bug report.
SELECT
  message_id,
  CASE
    WHEN BOOL_OR(list_name = 'pgsql-bugs') THEN 'pgsql-bugs'
    ELSE MIN(list_name)
  END AS source_list
FROM {{ ref('stg_list_messages') }}
GROUP BY ALL
