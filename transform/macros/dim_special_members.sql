-- Kimball special dimension members (Design Tip #128): every non-date dimension
-- carries two extra rows so a fact FK is never NULL --
--   Unknown        (generate_surrogate_key('-1')): a natural key that should
--                  have resolved to a real row but did not (a data-quality
--                  problem) -- flagged by the not_unknown_member test.
--   Not Applicable (generate_surrogate_key('-2')): the dimension legitimately
--                  does not apply to the fact row (no bug, .0 major, etc.).
-- The keys are universal sentinels (dim-agnostic hashes); each dimension holds
-- its own row for them. dim_date is exempt (it uses past_eternity /
-- future_eternity real rows instead -- see dim_date).

{% macro unknown_key() -%}
{{ dbt_utils.generate_surrogate_key(['-1']) }}
{%- endmacro %}


{% macro not_applicable_key() -%}
{{ dbt_utils.generate_surrogate_key(['-2']) }}
{%- endmacro %}

-- Note: a test's `where:` config can't call a macro (dbt's generic-test config
-- parser forbids it), so where a special row can't satisfy an attribute test we
-- exempt it by its placeholder natural key (e.g. cve_id NOT IN ('(unknown)',
-- '(not applicable)')), not by the surrogate hash.
