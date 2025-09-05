#!/bin/bash

# Hardened PostgreSQL startup and migration script
# Uses environment variables and applies secure schema with RLS and auditing.

set -euo pipefail

DB_NAME="${DB_NAME:-myapp}"
DB_PORT="${DB_PORT:-5000}"

# Admin user/role used for migrations (created locally if not exists)
DB_ADMIN_USER="${DB_ADMIN_USER:-app_admin}"
DB_ADMIN_PASSWORD="${DB_ADMIN_PASSWORD:-dbadmin123}"

# App runtime role and password (for backend usage)
APP_DB_USER="${APP_DB_USER:-app_rw}"
APP_DB_PASSWORD="${APP_DB_PASSWORD:-app_rw_pwd}"

echo "Starting PostgreSQL setup..."

# Find PostgreSQL version and set paths
PG_VERSION=$(ls /usr/lib/postgresql/ | head -1)
PG_BIN="/usr/lib/postgresql/${PG_VERSION}/bin"

echo "Found PostgreSQL version: ${PG_VERSION}"

# Check if PostgreSQL is already running on the specified port
if sudo -u postgres ${PG_BIN}/pg_isready -p ${DB_PORT} > /dev/null 2>&1; then
    echo "PostgreSQL is already running on port ${DB_PORT}!"
    echo "Database: ${DB_NAME}"
    echo "Admin User: ${DB_ADMIN_USER}"
    echo "Port: ${DB_PORT}"
    echo ""
    echo "To connect to the database, use:"
    echo "psql -h localhost -U ${DB_ADMIN_USER} -d ${DB_NAME} -p ${DB_PORT}"
    if [ -f "db_connection.txt" ]; then
        echo "Or use: $(cat db_connection.txt)"
    fi
else
    # Also check if there's a PostgreSQL process running (in case pg_isready fails)
    if pgrep -f "postgres.*-p ${DB_PORT}" > /dev/null 2>&1; then
        echo "Found existing PostgreSQL process on port ${DB_PORT}"
        echo "Attempting to verify connection..."
        if sudo -u postgres ${PG_BIN}/psql -p ${DB_PORT} -d ${DB_NAME} -c '\q' 2>/dev/null; then
            echo "Database ${DB_NAME} is accessible."
        fi
    fi

    # Initialize PostgreSQL data directory if it doesn't exist
    if [ ! -f "/var/lib/postgresql/data/PG_VERSION" ]; then
        echo "Initializing PostgreSQL..."
        sudo -u postgres ${PG_BIN}/initdb -D /var/lib/postgresql/data
    fi

    # Start PostgreSQL server in background
    echo "Starting PostgreSQL server..."
    sudo -u postgres ${PG_BIN}/postgres -D /var/lib/postgresql/data -p ${DB_PORT} &

    # Wait for PostgreSQL to start
    echo "Waiting for PostgreSQL to start..."
    for i in {1..20}; do
        if sudo -u postgres ${PG_BIN}/pg_isready -p ${DB_PORT} > /dev/null 2>&1; then
            echo "PostgreSQL is ready!"
            break
        fi
        echo "Waiting... ($i/20)"
        sleep 2
    done
fi

# Create database if not exists
sudo -u postgres ${PG_BIN}/createdb -p ${DB_PORT} ${DB_NAME} 2>/dev/null || echo "Database might already exist"

# Ensure admin login role exists and can connect
sudo -u postgres ${PG_BIN}/psql -p ${DB_PORT} -d postgres << EOF
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${DB_ADMIN_USER}') THEN
    CREATE ROLE ${DB_ADMIN_USER} WITH LOGIN SUPERUSER PASSWORD '${DB_ADMIN_PASSWORD}';
  ELSE
    ALTER ROLE ${DB_ADMIN_USER} WITH PASSWORD '${DB_ADMIN_PASSWORD}';
  END IF;
END
\$\$;

GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_ADMIN_USER};
EOF

# Save admin connection command to a file (local dev convenience)
echo "psql postgresql://${DB_ADMIN_USER}:${DB_ADMIN_PASSWORD}@localhost:${DB_PORT}/${DB_NAME}" > db_connection.txt
echo "Connection string saved to db_connection.txt"

# Apply migrations using migrate.sh
export DB_HOST=localhost
export DB_PORT
export DB_NAME
export DB_ADMIN_USER
export DB_ADMIN_PASSWORD

if [ -x "./migrate.sh" ]; then
  echo "Running migrations..."
  ./migrate.sh
else
  echo "migrate.sh not found or not executable; skipping migrations."
fi

# Configure app roles/passwords
if [ -x "./scripts/configure_roles.sh" ]; then
  echo "Configuring roles..."
  export APP_DB_USER
  export APP_DB_PASSWORD
  ./scripts/configure_roles.sh
else
  echo "Role configuration script missing; please run scripts/configure_roles.sh manually."
fi

# Save environment variables to a file for db_visualizer (dev only)
cat > db_visualizer/postgres.env << EOF
export POSTGRES_URL="postgresql://localhost:${DB_PORT}/${DB_NAME}"
export POSTGRES_USER="${APP_DB_USER}"
export POSTGRES_PASSWORD="${APP_DB_PASSWORD}"
export POSTGRES_DB="${DB_NAME}"
export POSTGRES_PORT="${DB_PORT}"
EOF

echo "PostgreSQL setup complete!"
echo "Database: ${DB_NAME}"
echo "Admin User: ${DB_ADMIN_USER}"
echo "App User: ${APP_DB_USER}"
echo "Port: ${DB_PORT}"
echo ""
echo "Environment variables saved to db_visualizer/postgres.env"
echo "To use with Node.js viewer, run: source db_visualizer/postgres.env"
echo "To connect to the database (admin), use one of the following commands:"
echo "psql -h localhost -U ${DB_ADMIN_USER} -d ${DB_NAME} -p ${DB_PORT}"
echo "$(cat db_connection.txt)"
