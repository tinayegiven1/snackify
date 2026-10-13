-- Creates the local Snackify database roles and databases. Safe to run more than once.
--
-- Run as the PostgreSQL superuser, with the two role passwords in environment variables
-- (PowerShell, from the project root):
--
--   $env:SNACKIFY_OWNER_PASSWORD = '<a long random password>'
--   $env:SNACKIFY_APP_PASSWORD   = '<another long random password>'
--   & 'C:\Program Files\PostgreSQL\18\bin\psql.exe' -h localhost -U postgres -d postgres -f database/setup/local-setup.sql
--
-- Then put the same passwords into backend/.env (see backend/.env.example).
--
-- Roles (least privilege):
--   snackify_owner  owns the databases and tables. Used only to run migrations.
--   snackify_app    used by the API. Can read and write data, cannot change the schema.

\set ON_ERROR_STOP on

\getenv owner_password SNACKIFY_OWNER_PASSWORD
\getenv app_password SNACKIFY_APP_PASSWORD
\if :{?owner_password}
\else
  \set owner_password ''
\endif
\if :{?app_password}
\else
  \set app_password ''
\endif

SELECT length(:'owner_password') >= 12 AND length(:'app_password') >= 12 AS passwords_ok \gset
\if :passwords_ok
\else
  DO $$ BEGIN
    RAISE EXCEPTION 'Set SNACKIFY_OWNER_PASSWORD and SNACKIFY_APP_PASSWORD (12+ characters) first.';
  END $$;
\endif

-- Roles
SELECT 'CREATE ROLE snackify_owner'
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'snackify_owner') \gexec
SELECT 'CREATE ROLE snackify_app'
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'snackify_app') \gexec

ALTER ROLE snackify_owner WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS
  PASSWORD :'owner_password';
ALTER ROLE snackify_app WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS
  PASSWORD :'app_password';

-- Store and compare timestamps in UTC everywhere. Business-local dates (Africa/Harare)
-- are calculated explicitly in queries, so results do not depend on the server's setting.
ALTER ROLE snackify_owner SET timezone TO 'UTC';
ALTER ROLE snackify_app SET timezone TO 'UTC';

-- Databases: one for development, one for automated tests, and an empty one that backups are
-- restored into to prove they work (npm run db:restore-check).
\set dbname snackify_dev
\ir setup-database.sql
\set dbname snackify_test
\ir setup-database.sql
\set dbname snackify_restore_check
\ir setup-database.sql

\echo 'Snackify roles and databases are ready.'
