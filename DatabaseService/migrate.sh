#!/usr/bin/env bash
set -euo pipefail

# Migration runner for DatabaseService
# Applies SQL files from sql/*.sql in lexicographical order.
# Requires environment variables (see .env.example). Do not store secrets in this script.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQL_DIR="${SCRIPT_DIR}/sql"

: "${DB_HOST:?DB_HOST is required}"
: "${DB_PORT:?DB_PORT is required}"
: "${DB_NAME:?DB_NAME is required}"
: "${DB_ADMIN_USER:?DB_ADMIN_USER is required}"
: "${DB_ADMIN_PASSWORD:?DB_ADMIN_PASSWORD is required}"

export PGPASSWORD="${DB_ADMIN_PASSWORD}"

PSQL="psql -v ON_ERROR_STOP=1 -h ${DB_HOST} -p ${DB_PORT} -U ${DB_ADMIN_USER} -d ${DB_NAME}"

echo "Applying migrations on ${DB_HOST}:${DB_PORT}/${DB_NAME} as ${DB_ADMIN_USER} ..."
echo "Using SQL directory: ${SQL_DIR}"

# Ensure migrations table exists
$PSQL <<'SQL'
CREATE SCHEMA IF NOT EXISTS audit;
CREATE TABLE IF NOT EXISTS audit.schema_migrations (
  id SERIAL PRIMARY KEY,
  filename TEXT UNIQUE NOT NULL,
  applied_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  checksum TEXT NOT NULL
);
SQL

shopt -s nullglob
FILES=( "${SQL_DIR}"/*.sql )

if [ ${#FILES[@]} -eq 0 ]; then
  echo "No SQL files found in ${SQL_DIR}"
  exit 0
fi

# Function to compute checksum
checksum_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    # fallback (not cryptographically strong)
    md5sum "$1" | awk '{print $1}'
  fi
}

APPLIED=0
SKIPPED=0

for f in "${FILES[@]}"; do
  base="$(basename "$f")"
  sum="$(checksum_file "$f")"

  exists=$($PSQL -tAc "SELECT 1 FROM audit.schema_migrations WHERE filename = '${base}'")
  if [[ "$exists" == "1" ]]; then
    prev_sum=$($PSQL -tAc "SELECT checksum FROM audit.schema_migrations WHERE filename = '${base}'")
    if [[ "$prev_sum" != "$sum" ]]; then
      echo "WARNING: Checksum mismatch for ${base}."
      echo "Previously applied migration differs from current file. Manual review recommended."
    fi
    echo "Skipping already applied: ${base}"
    ((SKIPPED++))
    continue
  fi

  echo "Applying: ${base}"
  $PSQL -f "$f"
  $PSQL -tAc "INSERT INTO audit.schema_migrations(filename, checksum) VALUES ('${base}', '${sum}')"
  ((APPLIED++))
done

echo "Migrations complete. Applied: ${APPLIED}, Skipped: ${SKIPPED}"
