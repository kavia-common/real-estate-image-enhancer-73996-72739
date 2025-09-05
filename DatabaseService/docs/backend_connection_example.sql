-- Example SQL snippets the backend can issue upon acquiring a connection

-- Set request context (RLS):
SELECT set_config('app.current_user_id', '00000000-0000-0000-0000-000000000000', true);

-- Insert image owned by current user:
INSERT INTO app.images (user_id, original_url, filename, mime_type, size_bytes)
VALUES (app.current_user_id(), 'https://storage/path/img1.jpg', 'img1.jpg', 'image/jpeg', 123456);

-- Safe read of own images:
SELECT id, filename, original_url, enhanced_url
FROM app.images
ORDER BY created_at DESC
LIMIT 50;

-- Log security event:
SELECT audit.log_event(
  app.current_user_id(),
  'agent',
  '127.0.0.1',
  'Mozilla/5.0',
  'UPLOAD_IMAGE',
  'app.images',
  NULL,
  'req-abc-123',
  '{"note":"user uploaded a new image"}'::jsonb
);
