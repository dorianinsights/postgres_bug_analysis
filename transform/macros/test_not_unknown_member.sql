-- Generic test: fails when a mandatory fact FK resolved to its dimension's
-- "Unknown" member -- i.e. a natural key that should have matched a real
-- dimension row did not. Legitimately-absent FKs point at the "Not Applicable"
-- member instead and are not checked here.
{% test not_unknown_member(model, column_name) %}
SELECT {{ column_name }}
FROM {{ model }}
WHERE {{ column_name }} = {{ unknown_key() }}
{% endtest %}
