-- Minimal seed data for local dev
-- Ensure test user (id from observability page) exists
insert into users (id, email, full_name, role, created_at)
values ('00000000-0000-0000-0000-000000000002', 'test.user@example.com', 'Test User', 'user', now())
on conflict (id) do nothing;

-- Basic active plan catalog (subscription_plans)
insert into subscription_plans (id, code, name, description, price_cents, included_chats, included_videos, pets_included_default, is_active, created_at)
values (gen_random_uuid(), 'plus', 'Plus', 'Starter plan', 19900, 5, 1, 2, true, now())
on conflict (code) do nothing;

-- Attach active subscription to test user (30d period)
insert into user_subscriptions (id, user_id, plan_id, status, started_at, current_period_start, current_period_end, created_at)
select gen_random_uuid(), u.id, p.id, 'active', now(), now(), now() + interval '30 days', now()
from users u join subscription_plans p on p.code = 'plus'
where u.id = '00000000-0000-0000-0000-000000000002'
and not exists (
  select 1 from user_subscriptions s where s.user_id = u.id and s.plan_id = p.id and s.status in ('trialing','active')
);

-- Seed a pet for the user (referenced by sample JSON pet_id)
insert into pets (id, user_id, name, species, weight_kg, medical_notes, created_at)
values ('11111111-1111-1111-1111-111111111111', '00000000-0000-0000-0000-000000000002', 'Firulais', 'dog', 12.4, 'Allergic to chicken', now())
on conflict (id) do nothing;

-- Simple vet_care_center entry used by /centers/near
insert into vet_care_centers (id, name, description, address, phone, is_partner, created_at)
values (gen_random_uuid(), 'Centro Vet MX', 'Primary test center', 'CDMX', '+52 555-000-0000', true, now())
on conflict (id) do nothing;

-- Optional: pre-create an empty chat session to exercise reserve endpoints (session created normally by /sessions/start)
-- (Commented out to avoid dangling rows)
-- insert into chat_sessions (id, user_id, status, created_at) values (gen_random_uuid(), '00000000-0000-0000-0000-000000000002', 'active', now());

-- Note: usage row will be auto-created on first fn_reserve_chat/fn_reserve_video call via fn_current_usage.
