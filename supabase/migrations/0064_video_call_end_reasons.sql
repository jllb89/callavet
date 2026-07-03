begin;

alter table public.video_session_lifecycle
  add column if not exists end_actor_role text
    check (end_actor_role is null or end_actor_role in ('owner', 'vet', 'admin', 'participant', 'system')),
  add column if not exists end_actor_user_id uuid references public.users(id) on delete set null,
  add column if not exists end_reason text
    check (end_reason is null or end_reason in ('owner_ended', 'vet_ended', 'admin_ended', 'network_disconnect', 'timeout_no_show', 'provider_room_finished', 'room_end', 'reconcile_timeout')),
  add column if not exists rejoin_eligible_until timestamptz,
  add column if not exists post_call_message_payload jsonb not null default '{}'::jsonb;

create index if not exists video_session_lifecycle_end_reason_idx
  on public.video_session_lifecycle (end_reason, room_finished_at desc)
  where end_reason is not null;

create index if not exists video_session_lifecycle_rejoin_idx
  on public.video_session_lifecycle (rejoin_eligible_until)
  where rejoin_eligible_until is not null;

comment on column public.video_session_lifecycle.end_actor_role is 'Participant role or system actor that ended the call when known.';
comment on column public.video_session_lifecycle.end_reason is 'Normalized call-end reason used by owner/vet post-call UX.';
comment on column public.video_session_lifecycle.rejoin_eligible_until is 'Short grace window for rejoining an active consult after an intentional room end.';
comment on column public.video_session_lifecycle.post_call_message_payload is 'Latest AI-generated post-call owner message payload for this video session.';

commit;