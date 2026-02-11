-- Sync Supabase auth.users into public.users for phone/email signups
-- Ensures phone-OTP logins create app user rows.

create or replace function public.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.users (id, email, full_name, phone, role, is_verified, created_at, updated_at)
  values (
    new.id,
    coalesce(new.email, new.id || '@placeholder.local'),
    null,
    new.phone,
    'user',
    coalesce(new.phone_confirmed_at is not null or new.email_confirmed_at is not null, false),
    now(),
    now()
  )
  on conflict (id) do update
    set phone = excluded.phone,
        email = coalesce(excluded.email, public.users.email),
        updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_on_auth_user_created on auth.users;
create trigger trg_on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_auth_user();
