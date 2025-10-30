-- Minimal seed data for local dev
insert into users (email) values ('admin@example.com') on conflict do nothing;
insert into plans (code,name,chat_quota,video_quota) values
  ('plus','Plus', 3, 1),
  ('cuadra','Cuadra', 10, 4)
  on conflict do nothing;
-- create a test center table if missing
create table if not exists centers (
  id serial primary key,
  name text not null,
  lat double precision default 19.4326,
  lng double precision default -99.1332
);
insert into centers (name) values ('Centro Vet MX') on conflict do nothing;
