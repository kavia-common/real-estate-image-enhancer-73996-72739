-- 001_init_schema.sql
-- Real Estate Image Enhancer - Secure PostgreSQL schema and roles initialization
-- This script is idempotent and can be run multiple times safely.

-- SECURITY AND ROLE SETUP
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_admin') THEN
    CREATE ROLE app_admin NOINHERIT LOGIN;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_rw') THEN
    CREATE ROLE app_rw NOINHERIT;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_ro') THEN
    CREATE ROLE app_ro NOINHERIT;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_audit') THEN
    CREATE ROLE app_audit NOINHERIT;
  END IF;
END
$$;

COMMENT ON ROLE app_admin IS 'Administrative role for migrations and maintenance. No implicit data access.';
COMMENT ON ROLE app_rw IS 'Application runtime role for read/write operations through backend.';
COMMENT ON ROLE app_ro IS 'Read-only role for safe querying/debugging.';
COMMENT ON ROLE app_audit IS 'Role with access to audit schemas.';

-- SCHEMAS
CREATE SCHEMA IF NOT EXISTS app AUTHORIZATION CURRENT_USER;
CREATE SCHEMA IF NOT EXISTS audit AUTHORIZATION CURRENT_USER;
CREATE SCHEMA IF NOT EXISTS ext AUTHORIZATION CURRENT_USER; -- external integration helpers

COMMENT ON SCHEMA app IS 'Primary application schema';
COMMENT ON SCHEMA audit IS 'Audit and compliance schema';
COMMENT ON SCHEMA ext IS 'External integration helpers (e.g., webhooks, queues)';

-- REVOKE PUBLIC ACCESS
REVOKE ALL ON SCHEMA public FROM PUBLIC;
REVOKE ALL ON SCHEMA app FROM PUBLIC;
REVOKE ALL ON SCHEMA audit FROM PUBLIC;
REVOKE ALL ON SCHEMA ext FROM PUBLIC;

-- GRANTS
GRANT USAGE ON SCHEMA app TO app_ro, app_rw, app_admin;
GRANT USAGE ON SCHEMA audit TO app_audit, app_admin;
GRANT USAGE ON SCHEMA ext TO app_admin, app_rw;

-- Ensure app_rw can create temp tables
GRANT TEMP ON DATABASE CURRENT_DATABASE() TO app_rw;

-- EXTENSIONS (safe, idempotent)
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS pgcrypto; -- for cryptographic functions
CREATE EXTENSION IF NOT EXISTS citext;   -- case-insensitive text, good for emails
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- ENUMS
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'user_role') THEN
    CREATE TYPE app.user_role AS ENUM ('agent', 'admin', 'viewer');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'subscription_status') THEN
    CREATE TYPE app.subscription_status AS ENUM ('trial', 'active', 'past_due', 'canceled');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'edit_status') THEN
    CREATE TYPE app.edit_status AS ENUM ('queued', 'processing', 'succeeded', 'failed');
  END IF;
END$$;

-- TABLES
CREATE TABLE IF NOT EXISTS app.users (
  id               UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  email            CITEXT UNIQUE NOT NULL,
  email_verified   BOOLEAN NOT NULL DEFAULT FALSE,
  password_hash    TEXT NOT NULL, -- hashed by backend (argon2/bcrypt), never plain text
  role             app.user_role NOT NULL DEFAULT 'agent',
  full_name        TEXT,
  company          TEXT,
  phone            TEXT,
  trial_images_quota INTEGER NOT NULL DEFAULT 10,
  trial_images_used  INTEGER NOT NULL DEFAULT 0,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  -- privacy: optional pseudonymous external id reference
  external_ref     TEXT
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_users_email_unique ON app.users (email);
CREATE INDEX IF NOT EXISTS idx_users_role ON app.users (role);

CREATE TABLE IF NOT EXISTS app.storage_locations (
  id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  provider    TEXT NOT NULL,  -- e.g., 's3', 'gcs', 'local'
  bucket      TEXT,
  base_path   TEXT,
  is_active   BOOLEAN NOT NULL DEFAULT TRUE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS app.images (
  id                UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id           UUID NOT NULL REFERENCES app.users(id) ON DELETE CASCADE,
  original_url      TEXT NOT NULL,  -- points to storage (never store raw blobs here)
  enhanced_url      TEXT,           -- set when completed
  thumbnail_url     TEXT,
  filename          TEXT NOT NULL,
  mime_type         TEXT NOT NULL,
  size_bytes        BIGINT NOT NULL CHECK (size_bytes >= 0),
  width             INTEGER,
  height            INTEGER,
  metadata          JSONB NOT NULL DEFAULT '{}'::jsonb,
  storage_location  UUID REFERENCES app.storage_locations(id),
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  deleted_at        TIMESTAMPTZ,
  CONSTRAINT images_user_fk FOREIGN KEY (user_id) REFERENCES app.users(id)
);

CREATE INDEX IF NOT EXISTS idx_images_user_id ON app.images (user_id);
CREATE INDEX IF NOT EXISTS idx_images_created_at ON app.images (created_at);
CREATE INDEX IF NOT EXISTS idx_images_deleted_at ON app.images (deleted_at);

CREATE TABLE IF NOT EXISTS app.edit_requests (
  id                UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id           UUID NOT NULL REFERENCES app.users(id) ON DELETE CASCADE,
  image_id          UUID NOT NULL REFERENCES app.images(id) ON DELETE CASCADE,
  prompt            TEXT NOT NULL,
  status            app.edit_status NOT NULL DEFAULT 'queued',
  status_detail     TEXT,
  external_job_id   TEXT, -- link to Google Nano Banana job or internal orchestrator id
  requested_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  started_at        TIMESTAMPTZ,
  completed_at      TIMESTAMPTZ,
  result_metadata   JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE INDEX IF NOT EXISTS idx_edit_requests_user_id ON app.edit_requests (user_id);
CREATE INDEX IF NOT EXISTS idx_edit_requests_image_id ON app.edit_requests (image_id);
CREATE INDEX IF NOT EXISTS idx_edit_requests_status ON app.edit_requests (status);

CREATE TABLE IF NOT EXISTS app.subscriptions (
  id                    UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id               UUID NOT NULL REFERENCES app.users(id) ON DELETE CASCADE,
  plan_id               TEXT NOT NULL, -- e.g., stripe price id
  status                app.subscription_status NOT NULL DEFAULT 'trial',
  current_period_start  TIMESTAMPTZ,
  current_period_end    TIMESTAMPTZ,
  cancel_at_period_end  BOOLEAN NOT NULL DEFAULT FALSE,
  quantity              INTEGER NOT NULL DEFAULT 1 CHECK (quantity > 0),
  images_quota          INTEGER NOT NULL DEFAULT 0 CHECK (images_quota >= 0),
  images_used           INTEGER NOT NULL DEFAULT 0 CHECK (images_used >= 0),
  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  external_customer_id  TEXT, -- e.g., Stripe Customer
  external_subscription_id TEXT -- e.g., Stripe Subscription
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_subscriptions_user_active_unique
  ON app.subscriptions (user_id)
  WHERE status IN ('trial','active','past_due');

CREATE TABLE IF NOT EXISTS app.payments (
  id               UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id          UUID NOT NULL REFERENCES app.users(id) ON DELETE CASCADE,
  subscription_id  UUID REFERENCES app.subscriptions(id) ON DELETE SET NULL,
  amount_cents     INTEGER NOT NULL CHECK (amount_cents >= 0),
  currency         TEXT NOT NULL DEFAULT 'usd',
  status           TEXT NOT NULL, -- e.g., 'succeeded','failed','pending','refunded'
  external_payment_id TEXT,       -- e.g., Stripe PaymentIntent
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  metadata         JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE INDEX IF NOT EXISTS idx_payments_user_id ON app.payments (user_id);
CREATE INDEX IF NOT EXISTS idx_payments_subscription_id ON app.payments (subscription_id);

-- AUDIT TABLES
CREATE TABLE IF NOT EXISTS audit.event_log (
  id           BIGSERIAL PRIMARY KEY,
  event_time   TIMESTAMPTZ NOT NULL DEFAULT now(),
  actor_user   UUID,                -- who performed action (nullable for system)
  actor_role   TEXT,                -- application role reported by backend
  ip_address   INET,
  user_agent   TEXT,
  action       TEXT NOT NULL,       -- e.g., 'LOGIN', 'UPLOAD_IMAGE', 'EDIT_REQUEST', 'ADMIN_ACTION'
  subject_table TEXT,               -- which table is impacted
  subject_id   TEXT,                -- uuid string or compound key
  request_id   TEXT,                -- correlation id from backend
  details      JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE INDEX IF NOT EXISTS idx_audit_event_time ON audit.event_log (event_time DESC);
CREATE INDEX IF NOT EXISTS idx_audit_actor_user ON audit.event_log (actor_user);

CREATE TABLE IF NOT EXISTS audit.data_changes (
  id            BIGSERIAL PRIMARY KEY,
  change_time   TIMESTAMPTZ NOT NULL DEFAULT now(),
  actor_user    UUID,
  table_name    TEXT NOT NULL,
  op            TEXT NOT NULL CHECK (op IN ('INSERT','UPDATE','DELETE')),
  pk            JSONB,           -- primary key values
  old_row       JSONB,
  new_row       JSONB,
  request_id    TEXT
);

CREATE INDEX IF NOT EXISTS idx_audit_data_changes_time ON audit.data_changes (change_time DESC);
CREATE INDEX IF NOT EXISTS idx_audit_data_changes_table ON audit.data_changes (table_name);

-- COMMON UPDATED_AT TRIGGER
CREATE OR REPLACE FUNCTION app.set_timestamp()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Attach to tables with updated_at
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'set_timestamp_users') THEN
    CREATE TRIGGER set_timestamp_users
    BEFORE UPDATE ON app.users
    FOR EACH ROW EXECUTE FUNCTION app.set_timestamp();
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'set_timestamp_images') THEN
    CREATE TRIGGER set_timestamp_images
    BEFORE UPDATE ON app.images
    FOR EACH ROW EXECUTE FUNCTION app.set_timestamp();
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'set_timestamp_edit_requests') THEN
    CREATE TRIGGER set_timestamp_edit_requests
    BEFORE UPDATE ON app.edit_requests
    FOR EACH ROW EXECUTE FUNCTION app.set_timestamp();
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'set_timestamp_subscriptions') THEN
    CREATE TRIGGER set_timestamp_subscriptions
    BEFORE UPDATE ON app.subscriptions
    FOR EACH ROW EXECUTE FUNCTION app.set_timestamp();
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'set_timestamp_payments') THEN
    CREATE TRIGGER set_timestamp_payments
    BEFORE UPDATE ON app.payments
    FOR EACH ROW EXECUTE FUNCTION app.set_timestamp();
  END IF;
END
$$;

-- AUDIT TRIGGER FUNCTION FOR DATA CHANGES
CREATE OR REPLACE FUNCTION audit.log_data_change()
RETURNS TRIGGER AS $$
DECLARE
  pk JSONB;
BEGIN
  -- Attempt to capture PK generically for UUID PK 'id'
  IF TG_OP = 'INSERT' THEN
    pk := jsonb_build_object('id', NEW.id);
    INSERT INTO audit.data_changes(table_name, op, pk, old_row, new_row)
    VALUES (TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME, TG_OP, pk, NULL, to_jsonb(NEW));
    RETURN NEW;
  ELSIF TG_OP = 'UPDATE' THEN
    pk := jsonb_build_object('id', NEW.id);
    INSERT INTO audit.data_changes(table_name, op, pk, old_row, new_row)
    VALUES (TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME, TG_OP, pk, to_jsonb(OLD), to_jsonb(NEW));
    RETURN NEW;
  ELSIF TG_OP = 'DELETE' THEN
    pk := jsonb_build_object('id', OLD.id);
    INSERT INTO audit.data_changes(table_name, op, pk, old_row, new_row)
    VALUES (TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME, TG_OP, pk, to_jsonb(OLD), NULL);
    RETURN OLD;
  END IF;
  RETURN NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Attach audit triggers to key tables
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'audit_users_changes') THEN
    CREATE TRIGGER audit_users_changes
    AFTER INSERT OR UPDATE OR DELETE ON app.users
    FOR EACH ROW EXECUTE FUNCTION audit.log_data_change();
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'audit_images_changes') THEN
    CREATE TRIGGER audit_images_changes
    AFTER INSERT OR UPDATE OR DELETE ON app.images
    FOR EACH ROW EXECUTE FUNCTION audit.log_data_change();
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'audit_edit_requests_changes') THEN
    CREATE TRIGGER audit_edit_requests_changes
    AFTER INSERT OR UPDATE OR DELETE ON app.edit_requests
    FOR EACH ROW EXECUTE FUNCTION audit.log_data_change();
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'audit_subscriptions_changes') THEN
    CREATE TRIGGER audit_subscriptions_changes
    AFTER INSERT OR UPDATE OR DELETE ON app.subscriptions
    FOR EACH ROW EXECUTE FUNCTION audit.log_data_change();
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'audit_payments_changes') THEN
    CREATE TRIGGER audit_payments_changes
    AFTER INSERT OR UPDATE OR DELETE ON app.payments
    FOR EACH ROW EXECUTE FUNCTION audit.log_data_change();
  END IF;
END
$$;

-- PRIVACY: MASKED VIEW FOR USERS (PII minimization)
CREATE OR REPLACE VIEW app.v_users_masked AS
SELECT
  id,
  -- mask email to reduce PII in read contexts not needing full email
  regexp_replace(email::text, '(^.).*(@.*$)', '\1****\2') AS email_masked,
  email_verified,
  role,
  -- Do not expose password_hash
  created_at, updated_at
FROM app.users;

-- ROW LEVEL SECURITY (RLS)
ALTER TABLE app.users ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.images ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.edit_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.subscriptions ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.payments ENABLE ROW LEVEL SECURITY;

-- Policies
-- Users: a user can see their own row (backend should SET ROLE app_rw and set app.current_user_id())
-- Use a secure mechanism: set_config('app.current_user_id', <uuid>, true)
CREATE OR REPLACE FUNCTION app.current_user_id() RETURNS uuid AS $$
  SELECT NULLIF(current_setting('app.current_user_id', true), '')::uuid;
$$ LANGUAGE sql STABLE;

-- If app_admin is running maintenance, bypass via role check
CREATE POLICY users_is_owner ON app.users
  FOR SELECT USING (id = app.current_user_id() OR current_user = 'app_admin');

CREATE POLICY users_update_self ON app.users
  FOR UPDATE USING (id = app.current_user_id() OR current_user = 'app_admin');

-- Images: owner-only visibility
CREATE POLICY images_is_owner ON app.images
  FOR SELECT USING (user_id = app.current_user_id() OR current_user = 'app_admin');

CREATE POLICY images_owner_mod ON app.images
  FOR UPDATE USING (user_id = app.current_user_id() OR current_user = 'app_admin');

CREATE POLICY images_owner_insert ON app.images
  FOR INSERT WITH CHECK (user_id = app.current_user_id() OR current_user = 'app_admin');

-- Edit requests: owner-only
CREATE POLICY edits_is_owner ON app.edit_requests
  FOR SELECT USING (user_id = app.current_user_id() OR current_user = 'app_admin');

CREATE POLICY edits_owner_mod ON app.edit_requests
  FOR UPDATE USING (user_id = app.current_user_id() OR current_user = 'app_admin');

CREATE POLICY edits_owner_insert ON app.edit_requests
  FOR INSERT WITH CHECK (user_id = app.current_user_id() OR current_user = 'app_admin');

-- Subscriptions: owner-only
CREATE POLICY subs_is_owner ON app.subscriptions
  FOR SELECT USING (user_id = app.current_user_id() OR current_user = 'app_admin');

CREATE POLICY subs_owner_mod ON app.subscriptions
  FOR UPDATE USING (user_id = app.current_user_id() OR current_user = 'app_admin');

CREATE POLICY subs_owner_insert ON app.subscriptions
  FOR INSERT WITH CHECK (user_id = app.current_user_id() OR current_user = 'app_admin');

-- Payments: owner-only
CREATE POLICY pay_is_owner ON app.payments
  FOR SELECT USING (user_id = app.current_user_id() OR current_user = 'app_admin');

CREATE POLICY pay_owner_mod ON app.payments
  FOR UPDATE USING (user_id = app.current_user_id() OR current_user = 'app_admin');

CREATE POLICY pay_owner_insert ON app.payments
  FOR INSERT WITH CHECK (user_id = app.current_user_id() OR current_user = 'app_admin');

-- GRANTS TO ROLES
-- app_ro: read masked and safe tables
GRANT SELECT ON app.v_users_masked TO app_ro;
GRANT SELECT ON app.images, app.edit_requests, app.subscriptions, app.payments TO app_ro;

-- app_rw: read/write subject to RLS
GRANT SELECT, INSERT, UPDATE, DELETE ON app.users, app.images, app.edit_requests, app.subscriptions, app.payments TO app_rw;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA app TO app_rw;

-- app_audit: read audit tables
GRANT SELECT ON audit.event_log, audit.data_changes TO app_audit;

-- app_admin: wide permissions (still audited)
GRANT USAGE ON SCHEMA app, audit, ext TO app_admin;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA app TO app_admin;
GRANT SELECT ON ALL TABLES IN SCHEMA audit TO app_admin;

-- COMPLIANCE: RESTRICT PUBLIC
REVOKE ALL ON ALL TABLES IN SCHEMA app FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA audit FROM PUBLIC;

-- HELPER: SAFE EMAIL LOOKUP FUNCTION (avoids exposing full email broadly)
CREATE OR REPLACE FUNCTION app.find_user_by_email(p_email CITEXT)
RETURNS UUID
LANGUAGE sql
STABLE
AS $$
  SELECT id FROM app.users WHERE email = p_email
$$;

COMMENT ON FUNCTION app.find_user_by_email(CITEXT) IS 'Returns user id for the given email without exposing other fields';

-- INDEX TUNING
CREATE INDEX IF NOT EXISTS idx_users_email_trgm ON app.users USING gin (email gin_trgm_ops);
-- Note: requires pg_trgm extension if used; not creating by default to keep minimal. Add in later migration if needed.

-- END
