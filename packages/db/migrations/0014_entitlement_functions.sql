-- 0014_entitlement_functions.sql
-- Clean path: align entitlement reserve functions with controller usage logic.
-- Removes dependency on view v_active_user_subscriptions so scheduled-cancel subscriptions
-- (cancel_at_period_end = true) still allow entitlement reservations until current_period_end.
-- Criteria: status = 'active' AND current_period_end > now().
-- Keeps existing fn_current_usage call to ensure usage row exists.

CREATE OR REPLACE FUNCTION fn_reserve_chat(p_user_id uuid, p_session_id uuid)
RETURNS TABLE(ok boolean, subscription_id uuid, consumption_id uuid, msg text)
LANGUAGE plpgsql
AS $$
DECLARE
  s user_subscriptions;
  u subscription_usage;
  c_id uuid;
BEGIN
  -- Select latest active (including scheduled-cancel) subscription still in its period
  SELECT * INTO s
  FROM user_subscriptions
  WHERE user_id = p_user_id
    AND status = 'active'
    AND coalesce(current_period_end, now()) > now()
  ORDER BY current_period_end DESC NULLS LAST
  LIMIT 1
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN QUERY SELECT false, NULL::uuid, NULL::uuid, 'no_active_subscription';
    RETURN;
  END IF;

  -- Ensure usage row exists / get current usage
  u := fn_current_usage(s.id);

  -- Attempt to consume one chat entitlement
  UPDATE subscription_usage
     SET consumed_chats = consumed_chats + 1,
         updated_at = now()
   WHERE id = u.id
     AND consumed_chats < included_chats
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
AS $$
DECLARE
  s user_subscriptions;
  u subscription_usage;
  c_id uuid;
BEGIN
  SELECT * INTO s
  FROM user_subscriptions
  WHERE user_id = p_user_id
    AND status = 'active'
    AND coalesce(current_period_end, now()) > now()
  ORDER BY current_period_end DESC NULLS LAST
  LIMIT 1
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN QUERY SELECT false, NULL::uuid, NULL::uuid, 'no_active_subscription';
    RETURN;
  END IF;

  u := fn_current_usage(s.id);

  UPDATE subscription_usage
     SET consumed_videos = consumed_videos + 1,
         updated_at = now()
   WHERE id = u.id
     AND consumed_videos < included_videos
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
