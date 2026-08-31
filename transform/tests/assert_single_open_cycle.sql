-- Exactly one cycle is open (the current one); zero or several means the
-- wrap-date derivation broke.
SELECT COUNT(*) AS open_cycles
FROM {{ ref('dim_release') }}
WHERE status = 'open'
HAVING COUNT(*) != 1
