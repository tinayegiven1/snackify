#!/bin/sh
# Runs once, when the PostgreSQL container starts with an empty data volume: creates the
# snackify_owner and snackify_app roles and the snackify database (database/setup).
set -e
psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d postgres -f /snackify-setup/cloud-setup.sql
