-- fct_messages must be exactly the message grain: one row per
-- stg_list_messages row, none lost or duplicated by the join into the person
-- dimension. A row here means the fact grain drifted from staging.
WITH counts AS (
  SELECT
    (SELECT COUNT(*) FROM {{ ref('fct_messages') }}) AS fct_cnt,
    (SELECT COUNT(*) FROM {{ ref('stg_list_messages') }}) AS stg_cnt
)

SELECT *
FROM counts
WHERE fct_cnt != stg_cnt
