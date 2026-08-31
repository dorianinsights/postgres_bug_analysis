{% macro export_marts_csv(results) %}
  {# on-run-end: export each successfully built mart to
     ../data/derived/<name>.csv, a diffable write-only audit artifact
     (committed, reviewed, never read back; the typed mart tables in the
     .duckdb file are the interface the faces and dbt tests consume). Row
     order: the export ORDERs BY ALL (every column, left to right) — the
     models themselves carry no final ORDER BY (a table has no reliable
     order; every consumer orders explicitly), so the exporter owns the
     determinism of the committed files.

     Size gate: only marts with FEWER than var('derived_csv_max_rows') rows
     get a CSV twin. A bigger table's diff is unreviewable and bloats the
     repo, so its typed .duckdb table stays the sole interface. This
     generalizes what used to be a hardcoded fct_messages exclusion (~160k
     rows, one row per archived message) into a threshold that also drops the
     other heavy marts (fct_commits, dim_person, dim_date, dim_bug,
     fct_fixes). If a mart grows past the threshold, git rm its stale CSV. #}
  {% set max_rows = var('derived_csv_max_rows') %}
  {% if execute %}
    {% for result in results %}
      {% set node = result.node %}
      {% if node.resource_type == 'model' and result.status | string == 'success' and 'marts' in node.fqn %}
        {% set qualified = node.schema ~ '.' ~ node.name %}
        {% set row_cnt = run_query('SELECT COUNT(*) FROM ' ~ qualified).rows[0][0] %}
        {% if row_cnt < max_rows %}
          {% set csv_path = '../data/derived/' ~ node.name ~ '.csv' %}
          {% do run_query("COPY (SELECT * FROM " ~ qualified ~ " ORDER BY ALL) TO '" ~ csv_path ~ "' (HEADER, DELIMITER ',')") %}
        {% endif %}
      {% endif %}
    {% endfor %}
  {% endif %}
{% endmacro %}
