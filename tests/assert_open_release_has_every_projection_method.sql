-- The open release is the live forecast: every projection method must have a
-- row for it (a replayed shipped release may lack early-slot methods, the open
-- one never should -- a missing method means a signal or ratio came back
-- NULL). Exception: under var(projection_min_window_days) of cycle age the
-- signal-family methods and their blend are withheld by design.
WITH open_release AS (
  SELECT
    dim_release_key,
    window_days
  FROM {{ ref('dim_release') }}
  WHERE status = 'open'
)

SELECT mth.projection_method
FROM {{ ref('projection_methods') }} AS mth
CROSS JOIN open_release AS opn
LEFT JOIN {{ ref('fct_fix_projections') }} AS prj
  ON opn.dim_release_key = prj.dim_release_key AND mth.projection_method = prj.projection_method
WHERE
  prj.projection_method IS null
  AND NOT (
    opn.window_days < {{ var('projection_min_window_days') }}
    AND (mth.method_family = 'signal' OR mth.projection_method = 'blended')
  )
