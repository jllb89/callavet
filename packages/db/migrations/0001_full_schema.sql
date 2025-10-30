-- Call a Vet - Minimal placeholder schema for local dev
-- NOTE: Replace with your full provided schema.

create table if not exists users (
  id uuid default gen_random_uuid() primary key,
  email text unique,
  created_at timestamptz default now()
);

create table if not exists plans (
  id serial primary key,
  code text unique not null,
  name text not null,
  chat_quota int default 0,
  video_quota int default 0
);

create table if not exists user_subscriptions (
  id serial primary key,
  user_id uuid references users(id),
  plan_id int references plans(id),
  current_period_start timestamptz,
  current_period_end timestamptz,
  status text default 'active'
);

create table if not exists subscription_usage (
  id serial primary key,
  subscription_id int references user_subscriptions(id),
  period_start timestamptz,
  period_end timestamptz,
  chat_used int default 0,
  video_used int default 0
);

create table if not exists sessions (
  id uuid default gen_random_uuid() primary key,
  external_id text,
  kind text check (kind in ('chat','video')),
  created_at timestamptz default now(),
  ended_at timestamptz
);

-- Minimal function stubs for smoke tests
create or replace function fn_reserve_chat(p_user_id uuid, p_session_id text)
returns json as $$
  select json_build_object('reserved', true, 'type','chat','sessionId', p_session_id);
$$ language sql stable;

create or replace function fn_reserve_video(p_user_id uuid, p_session_id text)
returns json as $$
  select json_build_object('reserved', true, 'type','video','sessionId', p_session_id);
$$ language sql stable;

create or replace function fn_commit(p_session_id text)
returns json as $$
  select json_build_object('committed', true, 'sessionId', p_session_id);
$$ language sql stable;

create or replace function fn_release(p_session_id text)
returns json as $$
  select json_build_object('released', true, 'sessionId', p_session_id);
$$ language sql stable;
