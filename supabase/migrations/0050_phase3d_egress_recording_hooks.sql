-- ============================================================
-- 0050: Phase 3D – Egress / Recording Hooks
-- ============================================================
-- Adds egress tracking columns to video_session_lifecycle so
-- LiveKit egress_started / egress_ended webhook events can be
-- stored and surfaced to admin without enabling recording yet.

BEGIN;

-- Egress state on the lifecycle row
ALTER TABLE public.video_session_lifecycle
  ADD COLUMN IF NOT EXISTS egress_id         text,
  ADD COLUMN IF NOT EXISTS egress_started_at timestamptz,
  ADD COLUMN IF NOT EXISTS egress_ended_at   timestamptz,
  ADD COLUMN IF NOT EXISTS recording_url     text;

COMMENT ON COLUMN public.video_session_lifecycle.egress_id
  IS 'LiveKit egressId from the most recent egress_started event for this room.';
COMMENT ON COLUMN public.video_session_lifecycle.recording_url
  IS 'Public/signed URL of the recorded file once the egress has ended, if available.';

COMMIT;
