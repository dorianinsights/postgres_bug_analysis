-- Exactly one cycle is open (the current one); zero or several means the
-- wrap-date derivation broke.
SELECT COUNT(*) AS open_cycles
FROM {{ ref('git_cycle_pace') }}
WHERE is_open_cycle
HAVING COUNT(*) != 1
