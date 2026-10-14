-- Creates or updates the two Snackify roles. Included by local-setup.sql and cloud-setup.sql;
-- do not run on its own. The passwords come from the environment variables
-- SNACKIFY_OWNER_PASSWORD and SNACKIFY_APP_PASSWORD.
--
-- Roles (least privilege):
--   snackify_owner  owns the databases and tables. Used only to run migrations and backups.
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

SELECT 'CREATE ROLE snackify_owner'
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'snackify_owner') \gexec
SELECT 'CREATE ROLE snackify_app'
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'snackify_app') \gexec

-- On managed PostgreSQL (Google Cloud SQL and similar), the admin account is not a superuser.
-- It cannot change the superuser, replication or RLS-bypass attributes, and does not need to:
-- roles it creates never have them.
SELECT rolsuper AS is_superuser FROM pg_roles WHERE rolname = current_user \gset
\if :is_superuser
  ALTER ROLE snackify_owner WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS
    PASSWORD :'owner_password';
  ALTER ROLE snackify_app WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS
    PASSWORD :'app_password';
\else
  ALTER ROLE snackify_owner WITH LOGIN NOCREATEDB NOCREATEROLE PASSWORD :'owner_password';
  ALTER ROLE snackify_app WITH LOGIN NOCREATEDB NOCREATEROLE PASSWORD :'app_password';
  -- The admin must be able to act as snackify_owner to create databases owned by it and to set
  -- its default privileges.
  GRANT snackify_owner TO CURRENT_USER;
\endif

-- Store and compare timestamps in UTC everywhere. Business-local dates (Africa/Harare)
-- are calculated explicitly in queries, so results do not depend on the server's setting.
ALTER ROLE snackify_owner SET timezone TO 'UTC';
ALTER ROLE snackify_app SET timezone TO 'UTC';
