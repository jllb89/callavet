begin;

create table if not exists public.notification_events (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references public.users(id) on delete set null,
  event_type text not null,
  channel text not null default 'email' check (channel in ('email', 'sms', 'whatsapp', 'push', 'system')),
  destination text,
  subject text,
  body_text text,
  template_id text,
  payload jsonb not null default '{}'::jsonb,
  status text not null default 'queued' check (status in ('queued', 'sent', 'failed', 'skipped')),
  provider text,
  provider_message_id text,
  error_text text,
  sent_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists notification_events_user_idx on public.notification_events (user_id, created_at desc);
create index if not exists notification_events_status_idx on public.notification_events (status, created_at desc);
create index if not exists notification_events_event_type_idx on public.notification_events (event_type, created_at desc);

create table if not exists public.admin_audit_logs (
  id uuid primary key default gen_random_uuid(),
  actor_user_id uuid references public.users(id) on delete set null,
  action text not null,
  target_type text,
  target_id text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists admin_audit_logs_action_idx on public.admin_audit_logs (action, created_at desc);
create index if not exists admin_audit_logs_actor_idx on public.admin_audit_logs (actor_user_id, created_at desc);

commit;
