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


{% macro past_eternity_dt() -%}
DATE '{{ var('past_eternity') }}'
{%- endmacro %}


{% macro future_eternity_dt() -%}
DATE '{{ var('future_eternity') }}'
{%- endmacro %}


{#
  The two special-member rows for a dimension, as UNION ALL branches over its
  projection `columns` (in order). key_column gets the sentinel key,
  is_synthetic_row is true, every other column is the SQL literal given in the
  `unknown` / `not_applicable` override maps, else NULL.
#}
{% macro special_member_rows(key_column, columns, unknown={}, not_applicable={}) %}
{%- for member in [(unknown_key(), unknown), (not_applicable_key(), not_applicable)] %}
UNION ALL
SELECT
{%- for col in columns %}
  {%- if col == key_column %}
  {{ member[0] }} AS {{ col }}
  {%- elif col == 'is_synthetic_row' %}
  true AS {{ col }}
  {%- else %}
  {{ member[1].get(col, 'null') }} AS {{ col }}
  {%- endif %}{{ ',' if not loop.last }}
{%- endfor %}
{%- endfor %}
{% endmacro %}

-- Note: a test's `where:` config can't call a macro (dbt's generic-test config
-- parser forbids it), so where a special row can't satisfy an attribute test we
-- exempt it by its placeholder natural key (e.g. cve_id NOT IN ('(unknown)',
-- '(not applicable)')), not by the surrogate hash.
