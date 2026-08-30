-- Exactly one cycle is open (the current one); zero or several means the
-- wrap-date derivation broke.
SELECT COUNT(*) AS open_cycles
FROM {{ ref('fct_release_cycles') }}
WHERE is_open_cycle
HAVING COUNT(*) != 1
