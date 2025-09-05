-- 002_audit_utils.sql
-- Centralized audit logging helpers

CREATE OR REPLACE FUNCTION audit.log_event(
  p_actor_user UUID,
  p_actor_role TEXT,
  p_ip INET,
  p_user_agent TEXT,
  p_action TEXT,
  p_subject_table TEXT,
  p_subject_id TEXT,
  p_request_id TEXT,
  p_details JSONB DEFAULT '{}'::jsonb
) RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_id BIGINT;
BEGIN
  INSERT INTO audit.event_log(actor_user, actor_role, ip_address, user_agent, action, subject_table, subject_id, request_id, details)
  VALUES (p_actor_user, p_actor_role, p_ip, p_user_agent, p_action, p_subject_table, p_subject_id, p_request_id, COALESCE(p_details, '{}'::jsonb))
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

COMMENT ON FUNCTION audit.log_event(UUID, TEXT, INET, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB)
IS 'Insert a standardized audit event. Backend should call after sensitive actions.';
