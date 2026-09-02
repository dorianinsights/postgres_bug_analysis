-- Absolute codebase size (total source lines) per released minor version -- an
-- aggregate fact conforming to dim_version on dim_version_key. This is the true
-- size of the tree at each release tag (from git grep), a per-branch stock, NOT
-- a cross-branch sum: each major's stable branch is a near-complete copy of the
-- tree, so lines are compared WITHIN a major over its minors and ACROSS majors,
-- never added together. Grain = dim_version_key. -> ../data/derived/fct_version_size_agg.csv
SELECT
  dvr.dim_version_key,
  siz.code_lines
FROM {{ ref('stg_version_sizes') }} AS siz
INNER JOIN {{ ref('dim_version') }} AS dvr ON siz.version = dvr.version
