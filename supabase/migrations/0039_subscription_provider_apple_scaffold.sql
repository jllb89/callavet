-- 0039_subscription_provider_apple_scaffold.sql
-- Multi-provider subscription scaffolding for Apple App Store support.

create table if not exists public.subscription_plan_provider_products (
  id uuid primary key default gen_random_uuid(),
  plan_id uuid not null references public.subscription_plans(id) on delete cascade,
  provider text not null,
  provider_product_id text not null,
  billing_period text,
  currency text,
  region text not null default 'GLOBAL',
  is_active boolean not null default true,
  metadata jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint subscription_plan_provider_products_provider_check
    check (provider in ('stripe', 'apple')),
  constraint subscription_plan_provider_products_billing_period_check
    check (billing_period is null or billing_period in ('month', 'year')),
  constraint subscription_plan_provider_products_unique
    unique (provider, provider_product_id, region)
);

create index if not exists subscription_plan_provider_products_plan_idx
  on public.subscription_plan_provider_products(plan_id);

create index if not exists subscription_plan_provider_products_lookup_idx
  on public.subscription_plan_provider_products(provider, provider_product_id)
  where is_active;

create table if not exists public.apple_subscription_events (
  id uuid primary key default gen_random_uuid(),
  event_id text not null,
  event_type text not null,
  environment text not null default 'sandbox',
  original_transaction_id text,
  transaction_id text,
  app_account_token uuid,
  product_id text,
  signed_payload text,
  payload jsonb,
  processed_at timestamptz,
  created_at timestamptz not null default now(),
  constraint apple_subscription_events_event_id_key unique (event_id),
  constraint apple_subscription_events_environment_check
    check (environment in ('sandbox', 'production'))
);

create index if not exists apple_subscription_events_otx_idx
  on public.apple_subscription_events(original_transaction_id);

create index if not exists apple_subscription_events_product_idx
  on public.apple_subscription_events(product_id);

create index if not exists apple_subscription_events_created_idx
  on public.apple_subscription_events(created_at desc);