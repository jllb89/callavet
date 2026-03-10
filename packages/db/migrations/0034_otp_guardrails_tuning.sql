create table if not exists public.otp_guard_events (
  id bigserial primary key,
  created_at timestamptz not null default now(),
  identifier text not null,
  channel text not null check (channel in ('sms','email')),
  action text not null check (action in ('send','verify_failed','verify_success')),
  ip_address text,
  meta jsonb not null default '{}'::jsonb
);

create index if not exists idx_otp_guard_events_identifier_created
  on public.otp_guard_events(identifier, created_at desc);

create index if not exists idx_otp_guard_events_ip_created
  on public.otp_guard_events(ip_address, created_at desc)
  where ip_address is not null;

create index if not exists idx_otp_guard_events_channel_action_created
  on public.otp_guard_events(channel, action, created_at desc);

create or replace function public.otp_guard_check_send(
  p_identifier text,
  p_channel text,
  p_ip_address text default null
)
returns table(
  allowed boolean,
  code text,
  message text,
  retry_after_seconds integer
)
language plpgsql
as $$
declare
  v_now timestamptz := now();
  v_last_send timestamptz;
  v_per_window_count integer;
  v_per_day_count integer;
  v_ip_window_count integer;
  v_ip_day_count integer;
  v_oldest_window_send timestamptz;
  v_oldest_ip_window_send timestamptz;
  v_window interval := interval '15 minutes';
  v_cooldown interval := interval '60 seconds';
  v_per_window_limit integer := 3;
  v_per_day_limit integer := case when p_channel = 'sms' then 6 else 12 end;
  v_ip_window_limit integer := 20;
  v_ip_day_limit integer := 150;
begin
  if p_identifier is null or btrim(p_identifier) = '' then
    return query select false, 'invalid_identifier', 'destino inválido.', null::integer;
    return;
  end if;

  select max(created_at)
    into v_last_send
  from public.otp_guard_events
  where identifier = p_identifier
    and channel = p_channel
    and action = 'send';

  if v_last_send is not null and v_now - v_last_send < v_cooldown then
    return query select
      false,
      'cooldown_active',
      'espera antes de pedir un nuevo código.',
      greatest(1, ceil(extract(epoch from (v_cooldown - (v_now - v_last_send))))::int);
    return;
  end if;

  select count(*)::int, min(created_at)
    into v_per_window_count, v_oldest_window_send
  from public.otp_guard_events
  where identifier = p_identifier
    and channel = p_channel
    and action = 'send'
    and created_at >= v_now - v_window;

  if v_per_window_count >= v_per_window_limit then
    return query select
      false,
      'too_many_requests_window',
      'demasiados intentos en poco tiempo. intenta de nuevo en unos minutos.',
      greatest(
        1,
        coalesce(
          ceil(extract(epoch from ((v_oldest_window_send + v_window) - v_now)))::int,
          900
        )
      );
    return;
  end if;

  select count(*)::int
    into v_per_day_count
  from public.otp_guard_events
  where identifier = p_identifier
    and channel = p_channel
    and action = 'send'
    and created_at >= v_now - interval '24 hours';

  if v_per_day_count >= v_per_day_limit then
    return query select
      false,
      'daily_cap_reached',
      'alcanzaste el máximo diario de códigos. intenta en 24 horas.',
      86400;
    return;
  end if;

  if p_ip_address is not null and btrim(p_ip_address) <> '' then
    select count(*)::int, min(created_at)
      into v_ip_window_count, v_oldest_ip_window_send
    from public.otp_guard_events
    where ip_address = p_ip_address
      and action = 'send'
      and created_at >= v_now - v_window;

    if v_ip_window_count >= v_ip_window_limit then
      return query select
        false,
        'ip_rate_limited_window',
        'demasiadas solicitudes desde tu red. intenta de nuevo en unos minutos.',
        greatest(
          1,
          coalesce(
            ceil(extract(epoch from ((v_oldest_ip_window_send + v_window) - v_now)))::int,
            900
          )
        );
      return;
    end if;

    select count(*)::int
      into v_ip_day_count
    from public.otp_guard_events
    where ip_address = p_ip_address
      and action = 'send'
      and created_at >= v_now - interval '24 hours';

    if v_ip_day_count >= v_ip_day_limit then
      return query select
        false,
        'ip_rate_limited_daily',
        'límite diario de solicitudes desde tu red alcanzado.',
        86400;
      return;
    end if;
  end if;

  return query select true, 'ok', 'allowed', 0;
end;
$$;

create or replace function public.otp_guard_record_send(
  p_identifier text,
  p_channel text,
  p_ip_address text default null
)
returns void
language sql
as $$
  insert into public.otp_guard_events(identifier, channel, action, ip_address)
  values (p_identifier, p_channel, 'send', p_ip_address);
$$;

create or replace function public.otp_guard_check_verify_lock(
  p_identifier text,
  p_channel text
)
returns table(
  allowed boolean,
  code text,
  message text,
  retry_after_seconds integer
)
language plpgsql
as $$
declare
  v_now timestamptz := now();
  v_failed_count integer;
  v_last_failed timestamptz;
  v_lock_threshold integer := 5;
  v_lock_window interval := interval '15 minutes';
  v_lock_duration interval := interval '15 minutes';
begin
  select count(*)::int, max(created_at)
    into v_failed_count, v_last_failed
  from public.otp_guard_events
  where identifier = p_identifier
    and channel = p_channel
    and action = 'verify_failed'
    and created_at >= v_now - v_lock_window;

  if v_failed_count >= v_lock_threshold and v_last_failed is not null and v_now - v_last_failed < v_lock_duration then
    return query select
      false,
      'verify_locked',
      'demasiados códigos incorrectos. espera antes de volver a intentar.',
      greatest(1, ceil(extract(epoch from (v_lock_duration - (v_now - v_last_failed))))::int);
    return;
  end if;

  return query select true, 'ok', 'allowed', 0;
end;
$$;

create or replace function public.otp_guard_record_verify_attempt(
  p_identifier text,
  p_channel text,
  p_success boolean,
  p_ip_address text default null
)
returns void
language plpgsql
as $$
begin
  insert into public.otp_guard_events(identifier, channel, action, ip_address)
  values (
    p_identifier,
    p_channel,
    case when p_success then 'verify_success' else 'verify_failed' end,
    p_ip_address
  );

  if p_success then
    delete from public.otp_guard_events
    where identifier = p_identifier
      and channel = p_channel
      and action = 'verify_failed'
      and created_at < now() - interval '15 minutes';
  end if;
end;
$$;
