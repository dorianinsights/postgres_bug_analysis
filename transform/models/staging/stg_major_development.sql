-- Typed per-major feature-development activity (from raw_major_development).
-- major_label and the first/last dev-commit UTC days are derived; the tag-ancestry
-- count and full instants are verbatim. Grain = major.
SELECT
  major::INTEGER AS major,
  'PG' || major AS major_label,
  dev_status,
  latest_milestone,
  dev_commit_cnt::BIGINT AS dev_commit_cnt,
  first_dev_commit_hash,
  first_dev_commit_ts::TIMESTAMPTZ AS first_dev_commit_ts,
  (first_dev_commit_ts::TIMESTAMPTZ AT TIME ZONE 'utc')::DATE AS first_dev_commit_dt,
  last_dev_commit_hash,
  last_dev_commit_ts::TIMESTAMPTZ AS last_dev_commit_ts,
  (last_dev_commit_ts::TIMESTAMPTZ AT TIME ZONE 'utc')::DATE AS last_dev_commit_dt
FROM {{ ref('raw_major_development') }}
