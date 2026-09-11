# pyright: strict
"""Build-time readers for the raw_* Python models.

One module per raw source, each a pure extractor that hands verbatim records
to a models/raw_*/ Python model (typing and filtering live in the SQL staging
models, never here):

- git   -- commits, tags, and per-commit file stats from the postgres.git clone
- sgml  -- release-notes changelog items parsed from the clone's DocBook SGML
- mail  -- pgsql-hackers messages decoded from the cached monthly mboxes

The dbt Python models import them as `pg_analysis.sources.<name>` from the
editable-installed package (no sys.path juggling anywhere); the readers take
every path from pg_analysis.paths and the corpus bounds from
pg_analysis.corpus, so they run the same from dbt, the backfills, and the
tests.
"""
