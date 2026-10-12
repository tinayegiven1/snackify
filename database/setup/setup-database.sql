-- Creates one Snackify database (name in :dbname) and sets its privileges.
-- Included by local-setup.sql; do not run on its own.

SELECT format('CREATE DATABASE %I OWNER snackify_owner ENCODING %L TEMPLATE template0', :'dbname', 'UTF8')
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'dbname') \gexec

-- Only the Snackify roles may connect (the owner can always connect).
REVOKE ALL ON DATABASE :"dbname" FROM PUBLIC;
GRANT CONNECT ON DATABASE :"dbname" TO snackify_app;

\connect :dbname

-- Only the owner may create tables. (PostgreSQL 15+ already does this; keep it explicit.)
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO snackify_app;

-- Tables and sequences that migrations create (as snackify_owner) are automatically
-- readable and writable by the API role. Migrations can revoke more where needed,
-- for example to make a ledger table append-only.
ALTER DEFAULT PRIVILEGES FOR ROLE snackify_owner IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO snackify_app;
ALTER DEFAULT PRIVILEGES FOR ROLE snackify_owner IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO snackify_app;

\connect postgres
