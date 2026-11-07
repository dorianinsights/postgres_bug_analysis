-- A reply roots its own thread only when nothing its headers name is archived
-- on its list: int_message_threads threads a reply onto the nearest archived id
-- of In-Reply-To or the References chain (JWZ threading's chain), not only its
-- direct parent. A row here is a reply left as its own thread although an
-- archived message it names would have placed it in one. (A parent cycle would
-- also land here; the corpus has none.)
WITH header_ids AS (
  SELECT
    list_name,
    message_id,
    UNNEST(LIST_CONCAT([in_reply_to], reference_ids)) AS header_id
  FROM {{ ref('stg_list_messages') }}
)

SELECT
  hdr.list_name,
  hdr.message_id,
  hdr.header_id
FROM header_ids AS hdr
INNER JOIN {{ ref('int_message_threads') }} AS imt
  ON hdr.list_name = imt.list_name AND hdr.message_id = imt.message_id
INNER JOIN {{ ref('int_message_threads') }} AS par
  ON hdr.list_name = par.list_name AND hdr.header_id = par.message_id
WHERE
  imt.is_thread_root
  AND NOT imt.is_thread_start
  AND hdr.header_id != hdr.message_id
