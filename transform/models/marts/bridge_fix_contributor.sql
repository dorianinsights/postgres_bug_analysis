-- Fix<->contributor bridge: one row per (fix, credited contributor) from the
-- release-notes "(Name, Name)" list, since a fix can credit several people.
-- Mirrors bridge_fix_cve / bridge_fix_bug. The contributor is the notes display
-- name -- a separate identity space from dim_person (email-keyed); reconciling
-- them is the person-alias future work. Grain = (item_ord, contributor).
SELECT
  item_ord,
  contributor
FROM {{ ref('int_fix_contributors') }}
