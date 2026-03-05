-- Keep auth -> public.users in sync when auth.users updates (e.g., phone/email confirmation)

-- Ensure the trigger fires on insert AND update
DROP TRIGGER IF EXISTS trg_on_auth_user_created ON auth.users;
DROP TRIGGER IF EXISTS trg_on_auth_user_upsert ON auth.users;
CREATE TRIGGER trg_on_auth_user_upsert
  AFTER INSERT OR UPDATE ON auth.users
  FOR EACH ROW EXECUTE PROCEDURE public.handle_new_auth_user();

-- Backfill is_verified (and contact fields) from auth.users to public.users
UPDATE public.users u
SET email = nullif(au.email, ''),
    full_name = coalesce(au.raw_user_meta_data->>'full_name', au.raw_app_meta_data->>'full_name'),
    phone = coalesce(au.phone, au.raw_user_meta_data->>'phone', au.raw_user_meta_data->>'phone_number', au.raw_app_meta_data->>'phone'),
    is_verified = coalesce(
      au.confirmed_at IS NOT NULL
      OR au.phone_confirmed_at IS NOT NULL
      OR au.email_confirmed_at IS NOT NULL,
      u.is_verified
    ),
    updated_at = now()
FROM auth.users au
WHERE au.id = u.id;
