-- The git-tag release registry and the SGML release notes must agree: every
-- registered release (a tag) has changelog items, and every version that
-- appears in the parsed items is a registered release. A row here means the two
-- have drifted -- a release tagged but not yet scraped into the notes, or items
-- parsed for a version that has no tag (e.g. a corpus/tag-pattern mismatch).
-- Replaces the former n_items checksum, which only compared two CSVs from the
-- same scrape run now that release existence comes from git rather than SGML.
WITH reg AS (SELECT version FROM {{ ref('int_versions') }}),

items AS (SELECT DISTINCT version FROM {{ ref('stg_release_items') }})

SELECT
  reg.version,
  'tag without items' AS issue
FROM reg
LEFT JOIN items ON reg.version = items.version
WHERE items.version IS null

UNION ALL

SELECT
  items.version,
  'items without tag' AS issue
FROM items
LEFT JOIN reg ON items.version = reg.version
WHERE reg.version IS null
