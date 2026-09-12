WITH item_hashes AS (
  SELECT
    version,
    item_index,
    LIST_SORT(LIST(DISTINCT commit_hash)) AS hash_set
  FROM {{ ref('stg_item_commits') }}
  GROUP BY ALL
),

items AS (
  SELECT
    rel.release_dt,
    rel.major,
    rel.minor,
    itm.version,
    itm.item_index,
    itm.summary,
    itm.full_text,
    LIST_SORT(LIST_DISTINCT(REGEXP_EXTRACT_ALL(itm.full_text, 'CVE-\d{4}-\d+'))) AS cve_list,
    ihs.hash_set
  FROM {{ ref('stg_release_items') }} AS itm
  INNER JOIN {{ ref('int_versions') }} AS rel ON itm.version = rel.version
  LEFT JOIN item_hashes AS ihs
    ON itm.version = ihs.version AND itm.item_index = ihs.item_index
  WHERE
    rel.minor > 0
    AND NOT REGEXP_MATCHES(itm.full_text, 'Update time zone data files', 'i')
)

SELECT
  ROW_NUMBER() OVER (ORDER BY major, minor, item_index) AS item_ord,
  release_dt,
  version,
  item_index,
  summary,
  full_text,
  CASE WHEN LEN(cve_list) > 0 THEN cve_list END AS cves,
  LOWER(TRIM(REGEXP_REPLACE(REPLACE(summary, '§', ' '), '\s+', ' ', 'g'))) AS text_key,
  hash_set
FROM items
