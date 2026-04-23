-- Migration 0044: Create vector_targets configuration table
-- Purpose: Store vector search target configurations dynamically instead of hardcoding in controllers
-- Tables affected: N/A (new table)
-- Breaking changes: None

begin;

-- Create vector_targets table
create table if not exists public.vector_targets (
  id text primary key,
  table_name text not null unique,
  embedding_column text not null,
  dimension int not null default 1536,
  snippet_expression text not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Index for efficient lookups
create index if not exists vector_targets_active_idx on public.vector_targets(is_active) where is_active = true;

-- Seed with current vector targets (from hardcoded vector.controller.ts)
-- Format: { table, embCol, snippet }
insert into public.vector_targets (
  id, table_name, embedding_column, dimension, snippet_expression, is_active
) values
  -- Knowledge base articles
  (
    'kb',
    'kb_articles',
    'embedding',
    1536,
    'left(coalesce(title,'''') || '' '' || coalesce(content,''''), 240)',
    true
  ),
  -- Chat messages
  (
    'messages',
    'messages',
    'embedding',
    1536,
    'left(coalesce(content,''''), 240)',
    true
  ),
  -- Consultation notes
  (
    'notes',
    'consultation_notes',
    'embedding',
    1536,
    'left(coalesce(summary_text,'''') || '' '' || coalesce(plan_summary,''''), 240)',
    true
  ),
  -- Products (placeholder, not yet fully implemented)
  (
    'products',
    'products',
    'embedding',
    1536,
    'left(coalesce(name,'''') || '' '' || coalesce(description,''''), 240)',
    true
  ),
  -- Services (placeholder, not yet fully implemented)
  (
    'services',
    'services',
    'embedding',
    1536,
    'left(coalesce(name,'''') || '' '' || coalesce(description,''''), 240)',
    true
  ),
  -- Pets/horses
  (
    'pets',
    'pets',
    'embedding',
    1536,
    'left(coalesce(name,'''') || '' '' || coalesce(breed,'''') || '' '' || coalesce(primary_activity,'''') || '' '' || coalesce(discipline,'''') || '' '' || coalesce(additional_notes,''''), 240)',
    true
  ),
  -- Veterinarians
  (
    'vets',
    'vets',
    'embedding',
    1536,
    'left(coalesce(full_name,'''') || '' '' || coalesce(bio,'''') || '' '' || array_to_string(specialties,'' ''), 240)',
    true
  )
on conflict (id) do nothing;

-- Trigger to auto-update updated_at
create or replace function trg_vector_targets_updated_at()
returns trigger as $$
begin
  new.updated_at = now();
  return new;
end;
$$ language plpgsql;

drop trigger if exists trg_vector_targets_updated_at on public.vector_targets;
create trigger trg_vector_targets_updated_at
  before update on public.vector_targets
  for each row
  execute function trg_vector_targets_updated_at();

-- RLS: admin only can modify
alter table public.vector_targets enable row level security;

drop policy if exists vector_targets_select_all on public.vector_targets;
create policy vector_targets_select_all on public.vector_targets
  for select
  using (true); -- Anyone can read

drop policy if exists vector_targets_insert_admin on public.vector_targets;
create policy vector_targets_insert_admin on public.vector_targets
  for insert
  with check (auth.jwt() ->> 'role' = 'admin' or exists(
    select 1 from public.users where id = auth.uid() and role = 'admin'
  ));

drop policy if exists vector_targets_update_admin on public.vector_targets;
create policy vector_targets_update_admin on public.vector_targets
  for update
  using (auth.jwt() ->> 'role' = 'admin' or exists(
    select 1 from public.users where id = auth.uid() and role = 'admin'
  ));

drop policy if exists vector_targets_delete_admin on public.vector_targets;
create policy vector_targets_delete_admin on public.vector_targets
  for delete
  using (auth.jwt() ->> 'role' = 'admin' or exists(
    select 1 from public.users where id = auth.uid() and role = 'admin'
  ));

commit;
