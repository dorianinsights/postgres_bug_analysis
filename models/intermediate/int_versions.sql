WITH wraps AS (
  SELECT
    major::VARCHAR || '.' || minor::VARCHAR AS version,
    major,
    minor,
    tag_dt AS wrap_dt
  FROM {{ ref('stg_git_tags') }}
  WHERE tag_kind = 'release'
),

item_counts AS (
  SELECT
    version,
    COUNT(*)::BIGINT AS item_cnt
  FROM {{ ref('stg_release_items') }}
  GROUP BY ALL
)

SELECT
  wrp.version,
  wrp.major,
  wrp.minor,
  wrp.wrap_dt,
  -- the announced release day: the first Thursday on/after the wrap.
  -- ISODOW arithmetic yields BIGINT; DATE + n needs INTEGER
  wrp.wrap_dt + (((4 - ISODOW(wrp.wrap_dt)) + 7) % 7)::INTEGER AS release_dt,
  itc.item_cnt
FROM wraps AS wrp
LEFT JOIN item_counts AS itc ON wrp.version = itc.version
