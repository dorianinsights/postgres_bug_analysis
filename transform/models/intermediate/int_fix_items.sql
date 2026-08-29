-- Every changelog item that counts as a fix (non-.0 release, not a routine
-- time-zone-data refresh), with the two dedup keys:
--
--   text_key  the summary lowercased, whitespace collapsed, "§" footnote
--             markers stripped — the wording the notes author copies
--             verbatim between branch files
--   hash_key  the exact sorted set of annotated commit hashes from
--             item_commits.csv (NULL when the item has no annotations)
--
-- item_ord numbers items in file order (major, minor, item_index) so the
-- dedup can pick the same representative build_datasets.py did: the first
-- item of each group in file order.
WITH item_hashes AS (
  SELECT
    version,
    item_index,
    ARRAY_TO_STRING(LIST_SORT(LIST(DISTINCT commit_hash)), ',') AS hash_set
  FROM {{ ref('stg_item_commits') }}
  GROUP BY version, item_index
)

SELECT
  ROW_NUMBER() OVER (ORDER BY rel.major, rel.minor, itm.item_index) AS item_ord,
  rel.release_dt AS wave_dt,
  itm.version,
  itm.item_index,
  itm.summary,
  itm.full_text,
  NULLIF(
    ARRAY_TO_STRING(LIST_SORT(LIST_DISTINCT(REGEXP_EXTRACT_ALL(itm.full_text, 'CVE-\d{4}-\d+'))), ';'),
    ''
  ) AS cves,
  't:' || LOWER(TRIM(REGEXP_REPLACE(REPLACE(itm.summary, '§', ' '), '\s+', ' ', 'g'))) AS text_key,
  CASE WHEN ihs.hash_set IS NOT null THEN 'h:' || ihs.hash_set END AS hash_key
FROM {{ ref('stg_release_items') }} AS itm
INNER JOIN {{ ref('stg_releases') }} AS rel ON itm.version = rel.version
LEFT JOIN item_hashes AS ihs
  ON itm.version = ihs.version AND itm.item_index = ihs.item_index
WHERE
  rel.minor > 0
  AND NOT REGEXP_MATCHES(itm.full_text, 'Update time zone data files', 'i')
