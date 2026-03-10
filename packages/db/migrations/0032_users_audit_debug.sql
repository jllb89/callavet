-- Debug audit log for users table writes (temporary for KYC/Auth tracing)
CREATE TABLE IF NOT EXISTS public.users_audit_debug (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  action text NOT NULL,
  user_id uuid,
  actor_sub text,
  old_email text,
  new_email text,
  old_phone text,
  new_phone text,
  old_full_name text,
  new_full_name text,
  old_country text,
  new_country text,
  old_state text,
  new_state text,
  old_is_verified boolean,
  new_is_verified boolean,
  old_updated_at timestamp,
  new_updated_at timestamp,
  created_at timestamp NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS users_audit_debug_user_id_idx
  ON public.users_audit_debug(user_id, created_at DESC);

CREATE OR REPLACE FUNCTION public.log_users_audit_debug()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  actor text;
BEGIN
  actor := current_setting('request.jwt.claims.sub', true);

  IF TG_OP = 'INSERT' THEN
    INSERT INTO public.users_audit_debug (
      action,
      user_id,
      actor_sub,
      new_email,
      new_phone,
      new_full_name,
      new_country,
      new_state,
      new_is_verified,
      new_updated_at
    ) VALUES (
      'INSERT',
      NEW.id,
      actor,
      NEW.email,
      NEW.phone,
      NEW.full_name,
      NEW.country,
      NEW.state,
      NEW.is_verified,
      NEW.updated_at
    );
    RETURN NEW;
  END IF;

  IF TG_OP = 'UPDATE' THEN
    INSERT INTO public.users_audit_debug (
      action,
      user_id,
      actor_sub,
      old_email,
      new_email,
      old_phone,
      new_phone,
      old_full_name,
      new_full_name,
      old_country,
      new_country,
      old_state,
      new_state,
      old_is_verified,
      new_is_verified,
      old_updated_at,
      new_updated_at
    ) VALUES (
      'UPDATE',
      NEW.id,
      actor,
      OLD.email,
      NEW.email,
      OLD.phone,
      NEW.phone,
      OLD.full_name,
      NEW.full_name,
      OLD.country,
      NEW.country,
      OLD.state,
      NEW.state,
      OLD.is_verified,
      NEW.is_verified,
      OLD.updated_at,
      NEW.updated_at
    );
    RETURN NEW;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_users_audit_debug ON public.users;
CREATE TRIGGER trg_users_audit_debug
AFTER INSERT OR UPDATE ON public.users
FOR EACH ROW
EXECUTE FUNCTION public.log_users_audit_debug();
