SELECT
  message_id,
  CASE
    WHEN BOOL_OR(list_name = 'pgsql-bugs') THEN 'pgsql-bugs'
    ELSE MIN(list_name)
  END AS source_list
FROM {{ ref('stg_list_messages') }}
GROUP BY ALL
