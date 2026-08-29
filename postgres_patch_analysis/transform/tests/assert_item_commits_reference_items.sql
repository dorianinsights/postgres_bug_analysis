-- Every commit annotation must belong to an item that exists (composite-key
-- referential integrity the built-in relationships test can't express).
SELECT
  itc.version,
  itc.item_index,
  itc.commit_hash
FROM {{ ref('stg_item_commits') }} AS itc
LEFT JOIN {{ ref('stg_release_items') }} AS itm
  ON itc.version = itm.version AND itc.item_index = itm.item_index
WHERE itm.version IS null
