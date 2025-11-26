-- 0020_overage_seed.sql
SET search_path = public;

INSERT INTO overage_items (code, name, description, currency, amount_cents, is_active, metadata)
VALUES
  ('chat_unit', 'Chat Unit', 'One chat message entitlement', 'mxn', 9900, true, '{"type":"chat","unit":1}'),
  ('video_unit', 'Video Unit', 'One video call entitlement', 'mxn', 19900, true, '{"type":"video","unit":1}'),
  ('emergency_consult', 'Emergency Consultation', 'Priority emergency consult session', 'mxn', 39900, true, '{"type":"emergency","unit":1}'),
  ('sms_unit', 'SMS Unit', 'One SMS message entitlement', 'mxn', 200, true, '{"type":"sms","unit":1}')
ON CONFLICT (code) DO UPDATE SET
  name=excluded.name,
  description=excluded.description,
  currency=excluded.currency,
  amount_cents=excluded.amount_cents,
  is_active=excluded.is_active,
  metadata=excluded.metadata,
  updated_at=now();
