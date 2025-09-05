-- 010_data_retention.sql
-- Optional policies to help with data retention and cleanup (privacy by design)

-- Soft delete helper to mark images as deleted (backend may also handle)
CREATE OR REPLACE FUNCTION app.soft_delete_image(p_image_id UUID, p_actor UUID)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
  UPDATE app.images
  SET deleted_at = now()
  WHERE id = p_image_id
    AND (user_id = app.current_user_id() OR current_user = 'app_admin');

  PERFORM audit.log_event(
    p_actor,
    'agent',
    NULL,
    NULL,
    'DELETE_IMAGE',
    'app.images',
    p_image_id::text,
    NULL,
    '{"reason":"user-initiated soft delete"}'::jsonb
  );
END;
$$;

COMMENT ON FUNCTION app.soft_delete_image(UUID, UUID) IS 'Marks image as soft-deleted and logs an audit event.';
