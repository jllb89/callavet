-- Improve auth->users sync to capture phone/full_name from metadata and backfill existing rows

-- Update sync function to pull phone/full_name from auth metadata
create or replace function public.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_full_name text := coalesce(new.raw_user_meta_data->>'full_name', new.raw_app_meta_data->>'full_name');
  v_phone     text := coalesce(new.phone, new.raw_user_meta_data->>'phone', new.raw_user_meta_data->>'phone_number', new.raw_app_meta_data->>'phone');
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
    set email = excluded.email,
        full_name = excluded.full_name,
        phone = excluded.phone,
        is_verified = excluded.is_verified,
        updated_at = now();
  return new;
end;
$$;

-- Backfill from auth.users to populate phone/full_name/is_verified on existing rows
update public.users u
set email = nullif(au.email, ''),
    full_name = coalesce(au.raw_user_meta_data->>'full_name', au.raw_app_meta_data->>'full_name'),
    phone = coalesce(au.phone, au.raw_user_meta_data->>'phone', au.raw_user_meta_data->>'phone_number', au.raw_app_meta_data->>'phone'),
    is_verified = coalesce(
      au.confirmed_at is not null
      or au.phone_confirmed_at is not null
      or au.email_confirmed_at is not null,
      u.is_verified
    ),
    updated_at = now()
from auth.users au
where au.id = u.id;

-- Refresh search vectors after backfill
update public.users
set email = email;
