-- 0054_entitlement_active_period_rule.sql
-- Align active entitlement selection across preview, reserve, usage, and scheduled-cancel behavior.

SET search_path = public;

CREATE OR REPLACE VIEW v_active_user_subscriptions AS
SELECT s.*
FROM user_subscriptions s
WHERE s.status = ANY (ARRAY['trialing'::text, 'active'::text])
  AND now() >= s.current_period_start
  AND now() < s.current_period_end;

CREATE OR REPLACE FUNCTION fn_reserve_chat(p_user_id uuid, p_session_id uuid)
RETURNS TABLE(ok boolean, subscription_id uuid, consumption_id uuid, msg text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  s user_subscriptions;
  u subscription_usage;
  c_id uuid;
BEGIN
  SELECT * INTO s
  FROM user_subscriptions
  WHERE user_id = p_user_id
    AND status = ANY (ARRAY['trialing'::text, 'active'::text])
    AND now() >= current_period_start
    AND now() < current_period_end
  ORDER BY current_period_end DESC NULLS LAST
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN QUERY SELECT false, NULL::uuid, NULL::uuid, 'no_active_subscription';
    RETURN;
  END IF;

  u := fn_current_usage(s.id);

  UPDATE subscription_usage su
     SET consumed_chats = su.consumed_chats + 1,
         updated_at = now()
   WHERE su.id = u.id
     AND su.subscription_id = s.id
     AND su.consumed_chats < su.included_chats
  RETURNING * INTO u;

  IF NOT FOUND THEN
    RETURN QUERY SELECT false, s.id, NULL::uuid, 'no_chat_entitlement_left';
    RETURN;
  END IF;

  INSERT INTO entitlement_consumptions (
    id, subscription_id, session_id, consumption_type, amount, source, created_at
  ) VALUES (
    gen_random_uuid(), s.id, p_session_id, 'chat', 1, 'system', now()
  ) RETURNING id INTO c_id;

  RETURN QUERY SELECT true, s.id, c_id, 'ok';
END;
$$;

CREATE OR REPLACE FUNCTION fn_reserve_video(p_user_id uuid, p_session_id uuid)
RETURNS TABLE(ok boolean, subscription_id uuid, consumption_id uuid, msg text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  s user_subscriptions;
  u subscription_usage;
  c_id uuid;
BEGIN
  SELECT * INTO s
  FROM user_subscriptions
  WHERE user_id = p_user_id
    AND status = ANY (ARRAY['trialing'::text, 'active'::text])
    AND now() >= current_period_start
    AND now() < current_period_end
  ORDER BY current_period_end DESC NULLS LAST
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN QUERY SELECT false, NULL::uuid, NULL::uuid, 'no_active_subscription';
    RETURN;
  END IF;

  u := fn_current_usage(s.id);

  UPDATE subscription_usage su
     SET consumed_videos = su.consumed_videos + 1,
         updated_at = now()
   WHERE su.id = u.id
     AND su.subscription_id = s.id
     AND su.consumed_videos < su.included_videos
  RETURNING * INTO u;

  IF NOT FOUND THEN
    RETURN QUERY SELECT false, s.id, NULL::uuid, 'no_video_entitlement_left';
    RETURN;
  END IF;

  INSERT INTO entitlement_consumptions (
    id, subscription_id, session_id, consumption_type, amount, source, created_at
  ) VALUES (
    gen_random_uuid(), s.id, p_session_id, 'video', 1, 'system', now()
  ) RETURNING id INTO c_id;

  RETURN QUERY SELECT true, s.id, c_id, 'ok';
END;
$$;