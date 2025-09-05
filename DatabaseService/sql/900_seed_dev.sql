-- 900_seed_dev.sql
-- Development seed data (DO NOT RUN IN PRODUCTION)
-- Uses placeholder password hashes; backend should manage real hashes.

INSERT INTO app.users (email, email_verified, password_hash, role, full_name, company, phone, trial_images_quota, trial_images_used)
VALUES
  ('agent1@example.com', true, '$2b$12$ABCDEFGHIJKLMNOPQRSTUvwxyz0123456789abcdefghi', 'agent', 'Agent One', 'Acme Realty', '+1 555-0001', 10, 0)
ON CONFLICT (email) DO NOTHING;

INSERT INTO app.storage_locations (provider, bucket, base_path, is_active)
VALUES ('local', NULL, '/data/images', TRUE)
ON CONFLICT DO NOTHING;
