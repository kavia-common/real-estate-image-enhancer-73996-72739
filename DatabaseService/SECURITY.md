Security and Compliance Overview

This DatabaseService implements multiple defense-in-depth controls:

1) Access Boundaries
- No direct frontend access. Only backend connects to the database.
- Least privilege roles: app_rw (runtime), app_ro (read-only), app_audit (audit logs), app_admin (migrations/maintenance).
- PUBLIC privileges revoked; explicit grants only.

2) Data Isolation
- Row-Level Security (RLS) enforces per-user access using app.current_user_id session parameter.
- Backend must set the parameter on every request transaction.

3) PII Minimization
- Passwords stored only as strong salted hashes (application responsibility).
- CITEXT for emails (case-insensitive) to avoid duplicate identities.
- Masked view app.v_users_masked prevents unnecessary PII exposure in read-only contexts.

4) Auditing
- Data change capture via AFTER triggers to audit.data_changes.
- Event logging via audit.log_event for security-relevant actions.
- Read access to audit tables limited to app_audit/app_admin.

5) Integrity and Constraints
- Foreign keys with cascades where appropriate.
- Check constraints on enums, positive integers for quotas/usages.
- Timestamps and updated_at triggers.

6) Migrations and DR
- Idempotent SQL migrations tracked by checksum in audit.schema_migrations.
- Backup/restore scripts for local env; production should use managed backups.

7) Secrets Management
- No secrets in repository. Use environment variables and secret stores.
- .env.example documents required environment variables.

8) Future Hardening
- TLS for connections.
- At-rest encryption (e.g., disk encryption/managed service).
- pg_trgm + partial indexes based on query profiling.
- Partitioning strategy for audit tables as they grow.
