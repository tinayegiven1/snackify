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
-- For a hosted server, use cloud-setup.sql instead.

\set ON_ERROR_STOP on
\ir setup-roles.sql

-- Databases: one for development, one for automated tests, and an empty one that backups are
-- restored into to prove they work (npm run db:restore-check).
\set dbname snackify_dev
\ir setup-database.sql
\set dbname snackify_test
\ir setup-database.sql
\set dbname snackify_restore_check
\ir setup-database.sql

\echo 'Snackify roles and databases are ready.'
