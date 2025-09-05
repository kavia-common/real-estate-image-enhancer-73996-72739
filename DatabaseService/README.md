# DatabaseService (PostgreSQL)

Secure, auditable PostgreSQL database layer for the Real Estate Image Enhancer platform.

Key features:
- Dedicated schemas: app (data), audit (logging), ext (integrations)
- Strict role-based access control (RBAC): app_admin, app_rw, app_ro, app_audit
- Row-Level Security (RLS) per-tenant/data-owner using app.current_user_id()
- Audit logs (event_log, data_changes) via triggers and helper functions
- PII minimization via masked views (app.v_users_masked)
- Idempotent migrations with checksums
- Data integrity constraints, indexes, and foreign keys
- Separation of DDL (SQL files) and credential management (scripts)

Important: Do not commit secrets. Use environment variables and CI/CD secret stores.

## Structure

- sql/
  - 001_init_schema.sql: Core roles, schemas, tables, RLS, grants, audit triggers
  - 002_audit_utils.sql: Audit helper function (audit.log_event)
  - 900_seed_dev.sql: Development-only seed data
- scripts/
  - configure_roles.sh: Configure role passwords and ensure role existence
- migrate.sh: Applies SQL migrations in lexical order, tracks in audit.schema_migrations
- .env.example: Example environment variables (do not use in production as-is)

## Operations

1) Initialize Postgres (use provided startup.sh if running locally)
2) Apply migrations:
   export DB_HOST=localhost
   export DB_PORT=5000
   export DB_NAME=myapp
   export DB_ADMIN_USER=app_admin
   export DB_ADMIN_PASSWORD=your_admin_password
   ./migrate.sh

3) Configure application roles/passwords:
   export APP_DB_USER=app_rw
   export APP_DB_PASSWORD=your_app_password
   # optional
   export AUDIT_DB_PASSWORD=your_audit_password
   ./scripts/configure_roles.sh

4) Backend connection:
   - Use APP_DB_USER/app_rw for runtime.
   - Backend should SET app.current_user_id during each request transaction:
     SELECT set_config('app.current_user_id', '<user-uuid>', true);
   - This enables RLS so users can only access their own data.

5) Auditing:
   - Backend can log explicit events:
     SELECT audit.log_event(<actor_user>, <actor_role>, <ip>, <ua>, <action>, <subject_table>, <subject_id>, <request_id>, <details_json>);
   - All data changes on app.* tables are captured by row-level triggers into audit.data_changes.

## Security and Compliance

- No direct access from frontend; only backend connects with least-privilege role.
- RLS ensures data isolation between users.
- Passwords are stored only as salted hashes (managed by backend).
- Emails are case-insensitive using CITEXT and masked when using app.v_users_masked.
- Audit records are immutable write-only from triggers; only readable by app_audit/app_admin.
- PUBLIC privileges revoked; grants are explicit.

## Backups

Use backup_db.sh and restore_db.sh for local environments.
For production, use managed snapshots and tested restore procedures.

## Notes

- The startup.sh included in this repo performs a minimal local setup with a sample database. For production, use hardened Postgres images, TLS, at-rest encryption, and managed secrets.
- Ensure statement_timeout and lock_timeout policies in production to avoid long locks during migrations.
- Add pg_trgm extension and trigram indexes if advanced search on email or text is required.

## License

Internal use for Real Estate Image Enhancer platform.
