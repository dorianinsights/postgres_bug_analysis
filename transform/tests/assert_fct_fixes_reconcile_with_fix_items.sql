-- fct_fixes must stay at the distinct-fix grain: exactly one row per distinct
-- fix, same as the item-grain fix_items fact. A row here means the star's fact
-- gained or lost fixes relative to the established grain (e.g. a bug/CVE join
-- fanned out instead of being aggregated).
WITH counts AS (
  SELECT
    (SELECT COUNT(*) FROM {{ ref('fct_fixes') }}) AS fct_cnt,
    (SELECT COUNT(*) FROM {{ ref('fix_items') }}) AS items_cnt
)

SELECT *
FROM counts
WHERE fct_cnt != items_cnt
