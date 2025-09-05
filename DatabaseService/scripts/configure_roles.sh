#!/usr/bin/env bash
set -euo pipefail

# Configure role memberships and passwords.
# Requires DB_ADMIN_USER to be a superuser or role with CREATEROLE and password change permissions.

: "${DB_HOST:?DB_HOST is required}"
: "${DB_PORT:?DB_PORT is required}"
: "${DB_NAME:?DB_NAME is required}"
: "${DB_ADMIN_USER:?DB_ADMIN_USER is required}"
: "${DB_ADMIN_PASSWORD:?DB_ADMIN_PASSWORD is required}"
: "${APP_DB_USER:?APP_DB_USER is required}"
: "${APP_DB_PASSWORD:?APP_DB_PASSWORD is required}"
: "${AUDIT_DB_USER:=app_audit}"
: "${AUDIT_DB_PASSWORD:=}"

export PGPASSWORD="${DB_ADMIN_PASSWORD}"

PSQL="psql -v ON_ERROR_STOP=1 -h ${DB_HOST} -p ${DB_PORT} -U ${DB_ADMIN_USER} -d ${DB_NAME}"

echo "Configuring roles on ${DB_HOST}:${DB_PORT}/${DB_NAME} ..."

$PSQL <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_admin') THEN
    CREATE ROLE app_admin NOINHERIT LOGIN;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_rw') THEN
    CREATE ROLE app_rw NOINHERIT LOGIN;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_ro') THEN
    CREATE ROLE app_ro NOINHERIT LOGIN;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_audit') THEN
    CREATE ROLE app_audit NOINHERIT LOGIN;
  END IF;
END
\$\$;

ALTER ROLE app_rw WITH PASSWORD '${APP_DB_PASSWORD}';
ALTER ROLE app_ro WITH PASSWORD '${APP_DB_PASSWORD}'; -- optional align; change if separate needed

-- Configure audit user password only if provided
SQL

if [[ -n "${AUDIT_DB_PASSWORD}" ]]; then
  $PSQL -c "ALTER ROLE app_audit WITH PASSWORD '${AUDIT_DB_PASSWORD}';"
fi

echo "Roles configured."
