-- 0040_auth_user_sync_preserve_profile.sql
-- Prevent auth.users sync from erasing profile fields in public.users.

create or replace function public.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_full_name text := nullif(coalesce(new.raw_user_meta_data->>'full_name', new.raw_app_meta_data->>'full_name'), '');
  v_phone     text := nullif(coalesce(new.phone, new.raw_user_meta_data->>'phone', new.raw_user_meta_data->>'phone_number', new.raw_app_meta_data->>'phone'), '');
  v_email     text := nullif(new.email, '');
  v_is_verified boolean := coalesce(
    new.confirmed_at is not null
    or new.phone_confirmed_at is not null
    or new.email_confirmed_at is not null,
    false
  );
begin
  insert into public.users (id, email, full_name, phone, role, is_verified, created_at, updated_at)
  values (
    new.id,
    v_email,
    v_full_name,
    v_phone,
    'user',
    v_is_verified,
    coalesce(new.created_at, now()),
    coalesce(new.updated_at, now())
  )
  on conflict (id) do update
    set email = coalesce(excluded.email, public.users.email),
        full_name = coalesce(excluded.full_name, public.users.full_name),
        phone = coalesce(excluded.phone, public.users.phone),
        is_verified = coalesce(public.users.is_verified, false) or coalesce(excluded.is_verified, false),
        updated_at = now();
  return new;
end;
$$;

-- Ensure trigger exists for both INSERT and UPDATE events.
DROP TRIGGER IF EXISTS trg_on_auth_user_created ON auth.users;
DROP TRIGGER IF EXISTS trg_on_auth_user_upsert ON auth.users;
CREATE TRIGGER trg_on_auth_user_upsert
  AFTER INSERT OR UPDATE ON auth.users
  FOR EACH ROW EXECUTE PROCEDURE public.handle_new_auth_user();

-- Safe sync pass: only fill missing fields, never null-out existing profile data.
UPDATE public.users u
SET
  email = coalesce(u.email, nullif(au.email, '')),
  full_name = coalesce(
    u.full_name,
    nullif(coalesce(au.raw_user_meta_data->>'full_name', au.raw_app_meta_data->>'full_name'), '')
  ),
  phone = coalesce(
    u.phone,
    nullif(coalesce(au.phone, au.raw_user_meta_data->>'phone', au.raw_user_meta_data->>'phone_number', au.raw_app_meta_data->>'phone'), '')
  ),
  is_verified = coalesce(u.is_verified, false)
    OR coalesce(
      au.confirmed_at IS NOT NULL
      OR au.phone_confirmed_at IS NOT NULL
      OR au.email_confirmed_at IS NOT NULL,
      false
    ),
  updated_at = now()
FROM auth.users au
WHERE au.id = u.id;
