WITH item_counts AS (
  SELECT
    version,
    COUNT(*)::BIGINT AS item_cnt
  FROM {{ ref('stg_release_items') }}
  GROUP BY ALL
)

SELECT
  tag.version,
  tag.major,
  tag.minor,
  tag.is_major_release,
  tag.stable_branch,
  tag.tag_dt AS wrap_dt,
  -- the announced release day: the first Thursday on/after the wrap.
  -- ISODOW arithmetic yields BIGINT; DATE + n needs INTEGER
  wrap_dt + (((4 - ISODOW(wrap_dt)) + 7) % 7)::INTEGER AS release_dt,
  itc.item_cnt
FROM {{ ref('stg_git_tags') }} AS tag
LEFT OUTER JOIN item_counts AS itc ON tag.version = itc.version
WHERE tag.tag_kind = 'release'
