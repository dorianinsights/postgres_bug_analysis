{% macro export_marts_csv(results) %}
  {# on-run-end: export each successfully built mart table to
     ../data/derived/<name>.csv. The CSVs are write-only audit artifacts
     (committed, reviewed, never read back); the typed mart tables in the
     .duckdb file are the interface the faces and dbt tests consume. Row
     order: the export ORDERs BY ALL (every column, left to right) — the
     models themselves carry no final ORDER BY (a table has no reliable
     order; every consumer orders explicitly), so the exporter owns the
     determinism of the committed files.

     Excluded: fct_messages — the message-grain fact is one row per archived
     message (~40 MB as CSV), too heavy to commit as a diffable twin. Its
     typed table in the .duckdb file stays the interface like every other
     mart; only its CSV audit export is skipped. #}
  {% set export_exclude = ['fct_messages'] %}
  {% if execute %}
    {% for result in results %}
      {% set node = result.node %}
      {% if node.resource_type == 'model' and result.status | string == 'success' and 'marts' in node.fqn and node.name not in export_exclude %}
        {% set csv_path = '../data/derived/' ~ node.name ~ '.csv' %}
        {% do run_query("COPY (SELECT * FROM " ~ node.schema ~ "." ~ node.name ~ " ORDER BY ALL) TO '" ~ csv_path ~ "' (HEADER, DELIMITER ',')") %}
      {% endif %}
    {% endfor %}
  {% endif %}
{% endmacro %}
