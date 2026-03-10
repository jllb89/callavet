-- Add location fields to user profile (MX-first, multi-country ready)
ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS country text,
  ADD COLUMN IF NOT EXISTS state text;

CREATE INDEX IF NOT EXISTS users_country_state_idx
  ON public.users (country, state);
