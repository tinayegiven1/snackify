-- Creates the Snackify roles and databases on a hosted PostgreSQL server (Google Cloud SQL or
-- similar), where the admin account is not a superuser. Safe to run more than once.
--
-- Run as the server's admin user (on Cloud SQL: postgres) through the Cloud SQL Auth Proxy,
-- with the two role passwords in environment variables. See docs/deployment.md.
--
-- Databases: snackify (the business data) and snackify_restore_check (empty; backups are
-- test-restored into it).

\set ON_ERROR_STOP on
\ir setup-roles.sql

\set dbname snackify
\ir setup-database.sql
\set dbname snackify_restore_check
\ir setup-database.sql

\echo 'Snackify roles and databases are ready.'
