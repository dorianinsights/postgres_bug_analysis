SELECT
  tag,
  major::INTEGER AS major,
  minor::INTEGER AS minor,
  date::DATE AS tag_date
FROM {{ source('scraped', 'git_tags') }}
