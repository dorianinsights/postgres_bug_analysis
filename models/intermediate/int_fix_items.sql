WITH item_hashes AS (
  SELECT
    version,
    item_index,
    LIST_SORT(LIST(DISTINCT commit_hash)) AS hash_set
  FROM {{ ref('stg_item_commits') }}
  GROUP BY ALL
)

SELECT
  ROW_NUMBER() OVER (ORDER BY rel.major, rel.minor, itm.item_index) AS item_ord,
  rel.release_dt,
  itm.version,
  itm.item_index,
  itm.summary,
  itm.full_text,
  NULLIF(LIST_SORT(LIST_DISTINCT(REGEXP_EXTRACT_ALL(itm.full_text, 'CVE-\d{4}-\d+'))), []) AS cves,
  LOWER(TRIM(REGEXP_REPLACE(REPLACE(itm.summary, '§', ' '), '\s+', ' ', 'g'))) AS text_key,
  ihs.hash_set
FROM {{ ref('stg_release_items') }} AS itm
INNER JOIN {{ ref('int_versions') }} AS rel ON itm.version = rel.version
LEFT OUTER JOIN item_hashes AS ihs
  ON itm.version = ihs.version AND itm.item_index = ihs.item_index
WHERE
  NOT rel.is_major_release
  AND NOT REGEXP_MATCHES(itm.full_text, 'Update time zone data files', 'i')
