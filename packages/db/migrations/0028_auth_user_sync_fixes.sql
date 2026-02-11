-- Make email optional for phone-first auth and improve auth->users sync

-- Allow null emails (phone-only accounts)
alter table if exists public.users
  alter column email drop not null;

-- Remove placeholder emails created by earlier syncs
update public.users
   set email = null
 where email like '%@placeholder.local';

-- Refresh search vectors after cleanup
update public.users
   set email = email;

-- Improved auth.users -> public.users sync
create or replace function public.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_full_name text := coalesce(new.raw_user_meta_data->>'full_name', new.raw_app_meta_data->>'full_name');
  v_phone     text := coalesce(new.phone, new.raw_user_meta_data->>'phone', new.raw_app_meta_data->>'phone');
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

-- Trigger already present; no change needed. This keeps it idempotent and uses the updated function.
