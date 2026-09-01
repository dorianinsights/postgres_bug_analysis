# pyright: strict
"""Build-time readers for the raw_* Python models.

One module per raw source, each a pure extractor that hands verbatim records
to a models/raw_*/ Python model (typing and filtering live in the SQL staging
models, never here):

- git   -- commits, tags, and per-commit file stats from the postgres.git clone
- sgml  -- release-notes changelog items parsed from the clone's DocBook SGML
- mail  -- pgsql-hackers messages decoded from the cached monthly mboxes

The models put transform/ (the dbt project root, dbt's cwd) on sys.path and
import `from sources.<name> import ...`; the readers reach the shared corpus
config one directory up (../corpus.py) the same way. Kept in one package
rather than loose at the project root so the readers stay together and the
root holds only dbt config.
"""
