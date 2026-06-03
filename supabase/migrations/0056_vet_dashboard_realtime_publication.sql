begin;

do $$
begin
  if not exists (
    select 1
      from pg_policies
     where schemaname = 'public'
       and tablename = 'appointments'
       and policyname = 'appointments_select_actor'
  ) then
    create policy appointments_select_actor on public.appointments
      for select
      using (user_id = auth.uid() or vet_id = auth.uid() or public.is_admin());
  end if;
end $$;

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    begin
      alter publication supabase_realtime add table public.chat_sessions;
    exception when duplicate_object then null;
    end;

    begin
      alter publication supabase_realtime add table public.appointments;
    exception when duplicate_object then null;
    end;

    begin
      alter publication supabase_realtime add table public.video_session_lifecycle;
    exception when duplicate_object then null;
    end;
  end if;
end $$;

commit;