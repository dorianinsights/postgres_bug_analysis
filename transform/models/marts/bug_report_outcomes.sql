-- One row per numbered pgsql-bugs report: was it acted upon (linked to a
-- commit via Discussion: trailer or bug-number mention), and how fast.
SELECT *
FROM {{ ref('int_bug_outcomes') }}
