-- =====================================================================
-- MOTHERLODE — UNIFIED COMPLETE DATABASE SETUP
-- Features included: Accounts, Lobbies, Leaderboards, PR Formula,
-- Tokens, Store, Messages, Notifications, Daily Chest, Knives, Roles, Badges,
-- Events (auto-schedule + admin unlock/lock).
-- Also: admin event editor (create / edit / delete), player insights for the Stats page,
-- and the one-ad-per-day limit is now enforced by the server.
--
-- ADMIN / HOST ACCESS: There is NO admin password. 
-- The Admin panel and Host panel call `panel_call()`. The server verifies 
-- the player's session and checks that they have the DEV badge (Admin panel) 
-- or HOST badge (Host panel) before executing any protected actions.
--
-- Safe to re-run at any time. Your data will be preserved.
-- =====================================================================

-- ---------- 0. CLEAN UP OLD PIECES ----------
drop trigger if exists on_auth_user_created on auth.users;
drop function if exists public.handle_new_user () cascade;
drop view if exists public.leaderboard;
drop table if exists public.profiles cascade;
drop table if exists public.player_badges cascade;
drop table if exists public.admin_cfg cascade;
drop function if exists public.touch_updated_at () cascade;
drop schema if exists admin cascade;

create extension if not exists pgcrypto with schema extensions;

-- ---------- 1. TABLES ----------
create table if not exists public.players (
  id uuid primary key default gen_random_uuid (),
  username text not null check (username ~ '^[A-Za-z0-9_]{3,16}$'),
  pass_hash text not null,
  banned boolean not null default false,
  created_at timestamptz not null default now(),
  bio text check (char_length(bio) <= 200),
  avatar text,
  wins int not null default 0,
  losses int not null default 0,
  kills int not null default 0,
  aces int not null default 0,
  deaths int not null default 0,
  pr numeric(7, 2) not null default 5000,
  streak int not null default 0,
  played int not null default 0,
  skips int not null default 0,
  tokens int not null default 0 check (tokens >= 0),
  last_chest date,
  badges text[] default '{}'
);

-- Everyone starts at 5000 PR (the PR formula is tuned for ~5000). 
alter table public.players alter column pr set default 5000;
update public.players set pr = 5000 where pr in (0, 1000) and wins = 0 and losses = 0 and kills = 0 and aces = 0 and deaths = 0;
alter table public.players drop column if exists elo;

create unique index if not exists players_username_key on public.players (lower(username));
create index if not exists players_pr_idx on public.players (pr desc);

create table if not exists public.sessions (
  token_hash text primary key,
  player_id uuid not null references public.players (id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '30 days'
);
create index if not exists sessions_player_idx on public.sessions (player_id);

-- Events must exist before lobbies (lobbies point at them).
create table if not exists public.events (
  key text primary key,
  name text not null,
  image text,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  -- auto = follows the schedule | on = admin unlocked (live until locked) | off = admin locked
  mode text not null default 'auto' check (mode in ('auto', 'on', 'off')),
  sort int not null default 0,
  created_at timestamptz not null default now(),
  blurb text,                                  -- short description shown on the event page
  format text,                                 -- e.g. '3-4 player lobbies'
  rules jsonb not null default '[]'::jsonb,    -- ["rule 1", "rule 2", ...]
  prizes jsonb not null default '[]'::jsonb,   -- [{"place":"1st","prize":"..."}, ...]
  check (ends_at > starts_at)
);
-- For databases that already had the events table:
alter table public.events
  add column if not exists blurb text,
  add column if not exists format text,
  add column if not exists rules jsonb not null default '[]'::jsonb,
  add column if not exists prizes jsonb not null default '[]'::jsonb;

create table if not exists public.lobbies (
  id uuid primary key default gen_random_uuid (),
  name text not null check (char_length(name) between 1 and 40),
  mode int not null check (mode in (3, 4)),
  status text not null default 'open' check (status in ('open', 'started', 'closed')),
  starts_at timestamptz,
  created_at timestamptz not null default now(),
  event_key text references public.events (key) on delete set null
);
-- For databases that already had lobbies before events existed:
alter table public.lobbies add column if not exists event_key text references public.events (key) on delete set null;

create table if not exists public.lobby_players (
  lobby_id uuid not null references public.lobbies (id) on delete cascade,
  player_id uuid not null references public.players (id) on delete cascade,
  picked boolean not null default false,
  spawn text,
  primary key (lobby_id, player_id)
);

create table if not exists public.lobby_results (
  id uuid primary key default gen_random_uuid (),
  lobby_id uuid not null references public.lobbies (id) on delete cascade,
  player_id uuid not null references public.players (id) on delete cascade,
  won boolean not null,
  place int check (place between 1 and 4),
  kills int not null default 0,
  deaths int not null default 0,
  aces int not null default 0,
  streak_before int not null default 0,
  pr_delta numeric(7, 2) not null default 0,
  tokens int not null default 0,
  saved_at timestamptz not null default now(),
  played_at timestamptz not null default now()
);
create index if not exists lobby_results_player_idx on public.lobby_results (player_id, played_at);

create table if not exists public.reports (
  id uuid primary key default gen_random_uuid (),
  reporter_id uuid not null references public.players (id) on delete cascade,
  reported_id uuid not null references public.players (id) on delete cascade,
  reason text not null check (char_length(reason) between 5 and 500),
  status text not null default 'open' check (status in ('open', 'dismissed', 'banned')),
  created_at timestamptz not null default now()
);

create table if not exists public.player_items (
  id uuid primary key default gen_random_uuid (),
  player_id uuid not null references public.players (id) on delete cascade,
  item text not null,
  source text not null default 'store',
  created_at timestamptz not null default now()
);
create index if not exists player_items_player_idx on public.player_items (player_id);

create table if not exists public.messages (
  id uuid primary key default gen_random_uuid (),
  from_id uuid not null references public.players (id) on delete cascade,
  to_id uuid not null references public.players (id) on delete cascade,
  body text not null check (char_length(body) between 1 and 500),
  created_at timestamptz not null default now(),
  read_at timestamptz
);
create index if not exists messages_to_idx on public.messages (to_id, created_at desc);

create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid (),
  to_id uuid references public.players (id) on delete cascade,
  title text not null check (char_length(title) between 1 and 80),
  body text not null check (char_length(body) between 1 and 500),
  created_at timestamptz not null default now()
);
create index if not exists notifications_created_idx on public.notifications (created_at desc);

create table if not exists public.notification_reads (
  notification_id uuid not null references public.notifications (id) on delete cascade,
  player_id uuid not null references public.players (id) on delete cascade,
  read_at timestamptz not null default now(),
  primary key (notification_id, player_id)
);

create table if not exists public.knives (
  key text primary key,
  name text not null,
  image text not null,
  sort int not null default 0,
  multi boolean not null default false,
  created_at timestamptz not null default now()
);

create table if not exists public.roles (
  key text primary key,
  name text not null,
  sort int not null default 0
);

create table if not exists public.player_roles (
  player_id uuid not null references public.players (id) on delete cascade,
  role_key text not null references public.roles (key) on delete cascade,
  primary key (player_id, role_key)
);

-- ---------- 2. DEFAULT DATA SEEDING ----------
insert into public.knives (key, name, image, sort, multi) values 
  ('knife_america', 'America', 'knives/america.png', 1, false),
  ('knife_biz_markies', 'Biz Markie''s', 'knives/biz_markies.png', 2, false),
  ('knife_biz_markies_subway', 'Biz Markie''s Subway', 'knives/biz_markies_subway.png', 3, false),
  ('knife_blue_christmas', 'Blue Christmas', 'knives/blue_christmas.png', 4, false),
  ('knife_case_hardened', 'Case Hardened', 'knives/case_hardened.png', 5, false),
  ('knife_johnnys_finalists', 'Johnny''s Finalists', 'knives/johnnys_finalists.png', 6, false),
  ('knife_johnnys_winners', 'Johnny''s Winners', 'knives/johnnys_winners.png', 7, false),
  ('knife_joker', 'Joker', 'knives/joker.png', 8, false),
  ('knife_junk_energy', 'Junk Energy', 'knives/junk_energy.png', 9, false),
  ('knife_michelle_obama_halloween', 'Michelle Obama Halloween', 'knives/michelle_obama_halloween.png', 10, false),
  ('knife_red_christmas', 'Red Christmas', 'knives/red_christmas.png', 11, false),
  ('knife_rick_ross_finalists', 'Rick Ross Finalists', 'knives/rick_ross_finalists.png', 12, false),
  ('knife_world_cup_25_finalists', 'World Cup ''25 Finalists', 'knives/world_cup_25_finalists.png', 13, false),
  ('knife_world_cup_25_winners', 'World Cup ''25 Winners', 'knives/world_cup_25_winners.png', 14, false),
  ('knife_world_cup_26_finalists', 'World Cup ''26 Finalists', 'knives/world_cup_26_finalists.png', 15, false),
  ('knife_world_cup_26_winners', 'World Cup ''26 Winners', 'knives/world_cup_26_winners.png', 16, false),
  ('kunai_knife', 'Kunai Knife', 'kunai.png', 17, true),
  ('halloween_knife', 'Halloween Knife', 'hknife.png', 18, true),
  ('1year_sticker', '1 Year Sticker', '1year.png', 19, true),
  ('wc25_sticker', 'World Cup 2025 Sticker', 'wc25.png', 20, true),
  ('titan_holo', 'Katowice 2014 Titan Holo Sticker', 'titan_holo.png', 21, true),
  ('knife_black_web', 'Black Web', 'knives/black_web.png', 22, false),
  ('knife_blue_graffiti', 'Blue Graffiti', 'knives/blue_graffiti.png', 23, false),
  ('knife_easter_sunrise', 'Easter Sunrise', 'knives/easter_sunrise.png', 24, false),
  ('knife_green_web', 'Green Web', 'knives/green_web.png', 25, false),
  ('knife_shadow_kunai', 'Shadow Kunai', 'knives/shadow_kunai.png', 26, false),
  ('knife_stattrack_asiimov', 'StatTrak Asiimov', 'knives/stattrack_asiimov.png', 27, false),
  ('knife_tidal_wave', 'Tidal Wave', 'knives/tidal_wave.png', 28, false),
  ('gloves_america', 'America Gloves', 'gloves/america_gloves.png', 29, false),
  ('gloves_blue_biker', 'Blue Biker Gloves', 'gloves/blue_biker_gloves.png', 30, false),
  ('gloves_cotton_candy_sport', 'Cotton Candy Sport Gloves', 'gloves/cotton_candy_sport_gloves.png', 31, false),
  ('gloves_orange_sport', 'Orange Sport Gloves', 'gloves/orange_sport_gloves.png', 32, false),
  ('gloves_purple_sport', 'Purple Sport Gloves', 'gloves/purple_sport_gloves.png', 33, false),
  ('gloves_shy', 'Shy Gloves', 'gloves/shy_gloves.png', 34, false)
on conflict (key) do update set image = excluded.image, sort = excluded.sort, multi = excluded.multi, 
  name = case when public.knives.name ~ '^World Cup 2[56] ' then excluded.name else public.knives.name end;

insert into public.roles (key, name, sort) values
  ('tournament_winner_2x', 'Tournament Winner 2x', 1),
  ('tournament_winner_1x', 'Tournament Winner 1x', 2),
  ('wc25_finalist', 'WC25 Finalist', 3),
  ('wc26_finalist', 'WC26 Finalist', 4),
  ('johnnys_cup_finalist', 'Johnny''s Cup Finalist', 5),
  ('rick_ross_cup_finalist', 'Rick Ross Cup Finalist', 6),
  ('taurus_cup_finalist', 'Taurus Cup Finalist', 7)
on conflict (key) do update set name = excluded.name, sort = excluded.sort;

-- Jon Taffer's Event: Oct 24, 3:00 PM - 11:00 PM Central time (America/Chicago).
-- Times / mode / any text you edit are NOT overwritten on re-run.
-- To add prizes later, e.g.:
--   update public.events set prizes = '[{"place":"1st","prize":"Halloween Knife"},{"place":"2nd","prize":"1,000 tokens"}]'::jsonb where key = 'jon_taffer_event';
insert into public.events (key, name, image, starts_at, ends_at, sort, blurb, format, rules) values (
  'jon_taffer_event', 'Jon Taffer''s Event', 'jon_taffer_event.png',
  ('2026-10-24 15:00:00'::timestamp at time zone 'America/Chicago'),
  ('2026-10-24 23:00:00'::timestamp at time zone 'America/Chicago'), 1,
  'Hop into the host''s lobbies and play as many games as you can. Every game you play counts toward the event leaderboard.',
  '3-4 player lobbies',
  '["Join an open lobby while the event is live. Every lobby the host creates during the event is part of it.","The host draws players for each game. Players who have played less and been skipped more get priority.","Each saved game adds or removes PR. Your event points are the net PR you earn during the event.","Standings are ranked by points, then wins, then kills."]'::jsonb)
on conflict (key) do update set name = excluded.name, image = excluded.image, sort = excluded.sort,
  blurb  = coalesce(public.events.blurb, excluded.blurb),
  format = coalesce(public.events.format, excluded.format),
  rules  = case when public.events.rules = '[]'::jsonb then excluded.rules else public.events.rules end;

-- ---------- 3. LOCK THE TABLES ----------
alter table public.reports enable row level security;
alter table public.lobby_results enable row level security;
alter table public.players enable row level security;
alter table public.sessions enable row level security;
alter table public.lobbies enable row level security;
alter table public.lobby_players enable row level security;
alter table public.player_items enable row level security;
alter table public.messages enable row level security;
alter table public.notifications enable row level security;
alter table public.notification_reads enable row level security;
alter table public.knives enable row level security;
alter table public.roles enable row level security;
alter table public.player_roles enable row level security;
alter table public.events enable row level security;

revoke all on public.reports, public.lobby_results, public.players, public.sessions, public.lobbies, 
public.lobby_players, public.player_items, public.messages, public.notifications, public.notification_reads, 
public.knives, public.roles, public.player_roles, public.events from anon, authenticated;

-- ---------- 4. PLAYER & AUTH FUNCTIONS ----------
create or replace function public.username_available (p_username text) returns boolean language sql stable security definer set search_path = public, extensions as $$
  select not exists (select 1 from public.players where lower(username) = lower(p_username));
$$;

create or replace function public.make_session (p_player uuid) returns text language plpgsql security definer set search_path = public, extensions as $$
declare tok text := encode(gen_random_bytes(32), 'hex');
begin
  delete from public.sessions where expires_at < now();
  insert into public.sessions (token_hash, player_id) values (encode(digest(tok, 'sha256'), 'hex'), p_player);
  return tok;
end $$;

create or replace function public.session_player (p_token text) returns uuid language sql security definer set search_path = public, extensions as $$
  select s.player_id from public.sessions s join public.players p on p.id = s.player_id
  where s.token_hash = encode(digest(p_token, 'sha256'), 'hex') and s.expires_at > now() and not p.banned;
$$;

create or replace function public.signup (p_username text, p_password text) returns json language plpgsql security definer set search_path = public, extensions as $$
declare pid uuid; uname text := trim(p_username);
begin
  if uname !~ '^[A-Za-z0-9_]{3,16}$' then raise exception 'BAD_USERNAME'; end if;
  if p_password is null or char_length(p_password) < 8 then raise exception 'BAD_PASSWORD'; end if;
  begin
    insert into public.players (username, pass_hash) values (uname, crypt(p_password, gen_salt('bf'))) returning id into pid;
  exception when unique_violation then
    raise exception 'USERNAME_TAKEN';
  end;
  return json_build_object('token', public.make_session(pid), 'username', uname);
end $$;

create or replace function public.login (p_username text, p_password text) returns json language plpgsql security definer set search_path = public, extensions as $$
declare p public.players;
begin
  select * into p from public.players where lower(username) = lower(trim(p_username));
  if not found or p.pass_hash <> crypt(p_password, p.pass_hash) then
    perform pg_sleep(0.4); raise exception 'INVALID_LOGIN';
  end if;
  if p.banned then raise exception 'BANNED'; end if;
  return json_build_object('token', public.make_session(p.id), 'username', p.username);
end $$;

create or replace function public.me (p_token text) returns json language sql security definer set search_path = public, extensions as $$
  select json_build_object('username', p.username, 'bio', p.bio, 'avatar', p.avatar,
         'wins', p.wins, 'losses', p.losses, 'kills', p.kills, 'aces', p.aces, 'deaths', p.deaths, 'pr', p.pr,
         'streak', p.streak, 'tokens', p.tokens, 'joined', p.created_at)
  from public.players p where p.id = public.session_player(p_token);
$$;

create or replace function public.logout (p_token text) returns void language sql security definer set search_path = public, extensions as $$
  delete from public.sessions where token_hash = encode(digest(p_token, 'sha256'), 'hex');
$$;

create or replace function public.update_profile (p_token text, p_bio text) returns void language plpgsql security definer set search_path = public, extensions as $$
declare pid uuid := public.session_player(p_token);
begin
  if pid is null then raise exception 'INVALID_SESSION'; end if;
  if char_length(coalesce(p_bio,'')) > 200 then raise exception 'BAD_BIO'; end if;
  update public.players set bio = nullif(trim(p_bio), '') where id = pid;
end $$;

create or replace function public.set_avatar (p_token text, p_avatar text) returns void language plpgsql security definer set search_path = public, extensions as $$
declare pid uuid := public.session_player(p_token);
begin
  if pid is null then raise exception 'INVALID_SESSION'; end if;
  if p_avatar is not null and (char_length(p_avatar) > 200000 or p_avatar !~ '^data:image/(png|jpeg|webp);base64,[A-Za-z0-9+/=]+$') then
    raise exception 'BAD_IMAGE';
  end if;
  update public.players set avatar = p_avatar where id = pid;
end $$;

-- ---------- 5. LEADERBOARD & GAME STATE ----------
create or replace function public.get_leaderboard (p_token text) returns json language plpgsql security definer set search_path = public, extensions as $$
begin
  if public.session_player(p_token) is null then raise exception 'INVALID_SESSION'; end if;
  return (
    select coalesce(json_agg(t order by t.rank), '[]'::json) from (
      select row_number() over (order by pr desc, wins desc, kills desc, lower(username)) as rank,
             username, bio, avatar, wins, losses, kills, aces, deaths, pr, streak, created_at as joined
      from public.players where not banned
      order by pr desc, wins desc, kills desc, lower(username) limit 100
    ) t);
end $$;

create or replace function public.list_players (p_token text, p_search text default '') returns json language plpgsql security definer set search_path = public, extensions as $$
begin
  if public.session_player(p_token) is null then raise exception 'INVALID_SESSION'; end if;
  return (
    select coalesce(json_agg(t order by lower(t.username)), '[]'::json) from (
      select username, bio, avatar, wins, losses, kills, aces, deaths, pr, streak, created_at as joined
      from public.players where not banned
        and (coalesce(trim(p_search),'') = '' or position(lower(trim(p_search)) in lower(username)) > 0)
      order by lower(username) limit 200
    ) t);
end $$;

-- game_state now also returns `events` and each lobby's `event_key`.
create or replace function public.game_state (p_token text) returns json language plpgsql security definer set search_path = public, extensions as $$
declare pid uuid := public.session_player(p_token);
begin
  if pid is null then raise exception 'INVALID_SESSION'; end if;
  perform public.assign_spawns(id) from public.lobbies where status = 'started';
  return json_build_object('now', now(),
    'unread', (select count(*) from public.messages where to_id=pid and read_at is null),
    'notif_unread', public.notif_unread_count(pid),
    'chest_ready', coalesce((select p.last_chest is distinct from public.chest_today() from public.players p where p.id=pid), false),
    'next_chest', public.chest_next_reset(),
    'ad_ready', not public.ad_claimed_today(pid),
    'next_ad', public.chest_next_reset(),
    'events', coalesce((select json_agg(json_build_object('key', e.key, 'name', e.name, 'image', e.image,
                'starts_at', e.starts_at, 'ends_at', e.ends_at, 'mode', e.mode,
                'blurb', e.blurb, 'format', e.format, 'rules', e.rules, 'prizes', e.prizes,
                'live', case e.mode when 'on' then true when 'off' then false else now() >= e.starts_at and now() < e.ends_at end)
                order by e.starts_at)
              from public.events e where e.mode <> 'auto' or e.ends_at > now() - interval '7 days'), '[]'::json),
    'last', (select json_build_object('lobby', l.name, 'won', r.won, 'kills', r.kills, 'deaths', r.deaths, 'aces', r.aces,
              'delta', r.pr_delta, 'tokens', r.tokens, 'at', r.saved_at)
             from public.lobby_results r join public.lobbies l on l.id=r.lobby_id
             where r.player_id=pid order by r.saved_at desc limit 1),
    'lobbies', coalesce((select json_agg(x order by x.created_at) from (
    select l.id, l.name, l.mode, l.status, l.starts_at, l.created_at, l.event_key,
      (select count(*) from public.lobby_players where lobby_id=l.id) as joined,
      exists (select 1 from public.lobby_players where lobby_id=l.id and player_id=pid) as me_in,
      exists (select 1 from public.lobby_players where lobby_id=l.id and player_id=pid and picked) as me_picked,
      case when l.status='open' and exists (select 1 from public.lobby_players where lobby_id=l.id and player_id=pid)
        then (select coalesce(json_agg(p.username order by p.username),'[]'::json)
              from public.lobby_players lp join public.players p on p.id=lp.player_id where lp.lobby_id=l.id) end as members,
      case when l.status='started' then (select coalesce(json_agg(p.username order by p.username),'[]'::json)
        from public.lobby_players lp join public.players p on p.id=lp.player_id where lp.lobby_id=l.id and lp.picked) end as roster,
      case when l.status='started' then (select lp.spawn from public.lobby_players lp where lp.lobby_id=l.id and lp.player_id=pid) end as my_spawn,
      case when l.status='started' then (select coalesce(json_object_agg(p.username, lp.spawn),'{}'::json)
        from public.lobby_players lp join public.players p on p.id=lp.player_id where lp.lobby_id=l.id and lp.picked) end as spawns
    from public.lobbies l where l.status <> 'closed') x), '[]'::json));
end $$;

create or replace function public.avatars_for (p_token text, p_names text[]) returns json language plpgsql security definer set search_path = public, extensions as $$
begin
  if public.session_player(p_token) is null then raise exception 'INVALID_SESSION'; end if;
  return coalesce((select json_object_agg(username, avatar) from public.players where not banned and username = any(p_names[1:50])), '{}'::json);
end $$;

create or replace function public.join_lobby (p_token text, p_lobby uuid) returns void language plpgsql security definer set search_path = public, extensions as $$
declare pid uuid := public.session_player(p_token);
begin
  if pid is null then raise exception 'INVALID_SESSION'; end if;
  if not exists (select 1 from public.lobbies where id=p_lobby and status='open') then raise exception 'That lobby is no longer open.'; end if;
  if exists (select 1 from public.lobby_players lp join public.lobbies l on l.id=lp.lobby_id where lp.player_id=pid and l.status<>'closed') then
    raise exception 'You are already in a game. Leave it first.'; end if;
  insert into public.lobby_players (lobby_id, player_id) values (p_lobby, pid);
end $$;

create or replace function public.leave_lobby (p_token text, p_lobby uuid) returns void language plpgsql security definer set search_path = public, extensions as $$
declare pid uuid := public.session_player(p_token);
begin
  if pid is null then raise exception 'INVALID_SESSION'; end if;
  delete from public.lobby_players where lobby_id=p_lobby and player_id=pid and exists (select 1 from public.lobbies where id=p_lobby and status='open');
end $$;

-- ---------- 6. STORE & ITEMS ----------
create or replace function public.my_items (p_token text) returns json language plpgsql security definer set search_path = public, extensions as $$
declare pid uuid := public.session_player(p_token);
begin
  if pid is null then raise exception 'INVALID_SESSION'; end if;
  return coalesce((select json_agg(json_build_object('item', t.item, 'n', t.n) order by t.item)
    from (select item, count(*) as n from public.player_items where player_id = pid group by item) t), '[]'::json);
end $$;

create or replace function public.player_inventory (p_token text, p_username text) returns json language plpgsql security definer set search_path = public, extensions as $$
declare tid uuid;
begin
  if public.session_player(p_token) is null then raise exception 'INVALID_SESSION'; end if;
  select id into tid from public.players where lower(username)=lower(p_username) and not banned;
  if tid is null then raise exception 'Player not found.'; end if;
  return coalesce((select json_agg(json_build_object('item', t.item, 'n', t.n) order by t.item)
    from (select item, count(*) as n from public.player_items where player_id = tid group by item) t), '[]'::json);
end $$;

create or replace function public.buy_item (p_token text, p_item text) returns json language plpgsql security definer set search_path = public, extensions as $$
declare pid uuid := public.session_player(p_token); v_price int; v_left int;
begin
  if pid is null then raise exception 'INVALID_SESSION'; end if;
  v_price := case p_item when 'nothing_for_sale' then 0 else null end;
  if v_price is null then raise exception 'That item isn''t for sale.'; end if;
  update public.players set tokens = tokens - v_price where id = pid and tokens >= v_price returning tokens into v_left;
  if not found then raise exception 'Not enough tokens.'; end if;
  insert into public.player_items (player_id, item, source) values (pid, p_item, 'store');
  return json_build_object('item', p_item, 'tokens', v_left);
end $$;

create or replace function public.open_case (p_token text) returns json language plpgsql security definer set search_path = public, extensions as $$
declare pid uuid := public.session_player(p_token); v_r double precision := random(); v_prize text; v_gain int := 0; v_left int;
begin
  if pid is null then raise exception 'INVALID_SESSION'; end if;
  if    v_r < 0.30 then v_prize := 'nothing';
  elsif v_r < 0.55 then v_prize := 'tokens'; v_gain := 100;
  elsif v_r < 0.75 then v_prize := 'jt_sticker';
  elsif v_r < 0.95 then v_prize := 'jt_sticker2';
  elsif v_r < 0.98 then v_prize := 'halloween_knife';
  else                  v_prize := 'kunai_knife'; end if;
  update public.players set tokens = tokens - 200 + v_gain where id = pid and tokens >= 200 returning tokens into v_left;
  if not found then raise exception 'Not enough tokens.'; end if;
  if v_prize in ('jt_sticker','jt_sticker2','halloween_knife','kunai_knife') then
    insert into public.player_items (player_id, item, source) values (pid, v_prize, 'jt_case');
  end if;
  return json_build_object('prize', v_prize, 'gain', v_gain, 'tokens', v_left);
end $$;

create or replace function public.sell_item (p_token text, p_item text) returns json language plpgsql security definer set search_path = public, extensions as $$
declare pid uuid := public.session_player(p_token); v_price int; v_gone uuid; v_left int;
begin
  if pid is null then raise exception 'INVALID_SESSION'; end if;
  v_price := case p_item when 'halloween_knife' then 1500 when 'kunai_knife' then 3000 when 'jt_sticker' then 100 when 'jt_sticker2' then 100 else null end;
  if v_price is null then raise exception 'That item can''t be sold.'; end if;
  delete from public.player_items where id = (select id from public.player_items where player_id = pid and item = p_item limit 1 for update) returning id into v_gone;
  if v_gone is null then raise exception 'You don''t own that item.'; end if;
  update public.players set tokens = tokens + v_price where id = pid returning tokens into v_left;
  return json_build_object('item', p_item, 'price', v_price, 'tokens', v_left);
end $$;

-- ---------- 7. MESSAGES ----------
create or replace function public.send_message (p_token text, p_to text, p_body text) returns void language plpgsql security definer set search_path = public, extensions as $$
declare pid uuid := public.session_player(p_token); tid uuid; v_body text := trim(coalesce(p_body,''));
begin
  if pid is null then raise exception 'INVALID_SESSION'; end if;
  select id into tid from public.players where lower(username)=lower(p_to) and not banned;
  if tid is null then raise exception 'Player not found.'; end if;
  if tid = pid then raise exception 'You can''t message yourself.'; end if;
  if char_length(v_body) < 1 then raise exception 'Write a message first.'; end if;
  if char_length(v_body) > 500 then raise exception 'Message is too long (500 characters max).'; end if;
  if (select count(*) from public.messages where from_id=pid and created_at > now() - interval '1 minute') >= 8 then raise exception 'Slow down — you''re sending messages too fast.'; end if;
  if (select count(*) from public.messages where from_id=pid and to_id=tid and read_at is null) >= 20 then raise exception 'That player has too many unread messages from you.'; end if;
  insert into public.messages (from_id, to_id, body) values (pid, tid, v_body);
end $$;

create or replace function public.inbox (p_token text) returns json language plpgsql security definer set search_path = public, extensions as $$
declare pid uuid := public.session_player(p_token);
begin
  if pid is null then raise exception 'INVALID_SESSION'; end if;
  return coalesce((select json_agg(x order by x.created_at desc) from (
    select m.id, p.username as from_user, p.avatar, m.body, m.created_at, (m.read_at is not null) as read
    from public.messages m join public.players p on p.id = m.from_id
    where m.to_id = pid and not p.banned order by m.created_at desc limit 50) x), '[]'::json);
end $$;

create or replace function public.messages_read (p_token text) returns void language plpgsql security definer set search_path = public, extensions as $$
declare pid uuid := public.session_player(p_token);
begin
  if pid is null then raise exception 'INVALID_SESSION'; end if;
  update public.messages set read_at = now() where to_id = pid and read_at is null;
end $$;

create or replace function public.delete_message (p_token text, p_id uuid) returns void language plpgsql security definer set search_path = public, extensions as $$
declare pid uuid := public.session_player(p_token);
begin
  if pid is null then raise exception 'INVALID_SESSION'; end if;
  delete from public.messages where id = p_id and to_id = pid;
end $$;

-- ---------- 8. NOTIFICATIONS & CHEST ----------
create or replace function public.chest_today () returns date language sql stable set search_path = public, extensions as $$
  select (now() at time zone 'America/Chicago')::date;
$$;

create or replace function public.chest_next_reset () returns timestamptz language sql stable set search_path = public, extensions as $$
  select ((public.chest_today() + 1)::timestamp at time zone 'America/Chicago');
$$;

create or replace function public.notif_unread_count (p_player uuid) returns int language sql stable security definer set search_path = public, extensions as $$
  select count(*)::int from public.notifications n, public.players p
  where p.id = p_player and (n.to_id = p.id or (n.to_id is null and n.created_at >= p.created_at))
    and not exists (select 1 from public.notification_reads r where r.notification_id = n.id and r.player_id = p.id);
$$;

create or replace function public.my_notifications (p_token text) returns json language plpgsql security definer set search_path = public, extensions as $$
declare pid uuid := public.session_player(p_token); v_joined timestamptz;
begin
  if pid is null then raise exception 'INVALID_SESSION'; end if;
  select created_at into v_joined from public.players where id = pid;
  return coalesce((select json_agg(x order by x.created_at desc) from (
    select n.id, n.title, n.body, n.created_at, (n.to_id is not null) as direct,
           exists (select 1 from public.notification_reads r where r.notification_id = n.id and r.player_id = pid) as read
    from public.notifications n where n.to_id = pid or (n.to_id is null and n.created_at >= v_joined)
    order by n.created_at desc limit 50) x), '[]'::json);
end $$;

create or replace function public.notifications_read (p_token text) returns void language plpgsql security definer set search_path = public, extensions as $$
declare pid uuid := public.session_player(p_token); v_joined timestamptz;
begin
  if pid is null then raise exception 'INVALID_SESSION'; end if;
  select created_at into v_joined from public.players where id = pid;
  insert into public.notification_reads (notification_id, player_id)
    select n.id, pid from public.notifications n where n.to_id = pid or (n.to_id is null and n.created_at >= v_joined)
  on conflict do nothing;
end $$;

create or replace function public.open_daily_chest (p_token text) returns json language plpgsql security definer set search_path = public, extensions as $$
declare pid uuid := public.session_player(p_token); v_today date := public.chest_today(); v_last date; v_r double precision := random(); v_tier text; v_amt int; v_left int;
begin
  if pid is null then raise exception 'INVALID_SESSION'; end if;
  select last_chest into v_last from public.players where id = pid for update;
  if v_last = v_today then raise exception 'ALREADY_OPENED'; end if;
  if    v_r < 0.45 then v_tier := 'common';    v_amt := 50;
  elsif v_r < 0.72 then v_tier := 'uncommon';  v_amt := 100;
  elsif v_r < 0.87 then v_tier := 'rare';      v_amt := 150;
  elsif v_r < 0.95 then v_tier := 'epic';      v_amt := 250;
  elsif v_r < 0.99 then v_tier := 'legendary'; v_amt := 350;
  else                  v_tier := 'mythic';    v_amt := 500; end if;
  update public.players set tokens = tokens + v_amt, last_chest = v_today where id = pid returning tokens into v_left;
  return json_build_object('tier', v_tier, 'amount', v_amt, 'tokens', v_left, 'next_at', public.chest_next_reset());
end $$;

-- ---------- 9. ROLES & BADGES DISPLAY ----------
create or replace function public.get_roles (p_token text) returns json language plpgsql security definer set search_path = public, extensions as $$
begin
  if public.session_player(p_token) is null then raise exception 'INVALID_SESSION'; end if;
  return json_build_object(
    'defs', coalesce((select json_agg(json_build_object('key', r.key, 'name', r.name) order by r.sort) from public.roles r), '[]'::json),
    'map',  coalesce((select json_object_agg(x.username, x.keys) from (
               select p.username, json_agg(pr.role_key order by r.sort) as keys from public.player_roles pr
               join public.roles r on r.key = pr.role_key join public.players p on p.id = pr.player_id
               where not p.banned group by p.username) x), '{}'::json));
end $$;

create or replace function public.get_badges (p_token text) returns json language plpgsql security definer set search_path = public, extensions as $$
begin
  if public.session_player(p_token) is null then raise exception 'INVALID_SESSION'; end if;
  return coalesce((select json_object_agg(username, to_json(badges)) from public.players where not banned and cardinality(coalesce(badges,'{}')) > 0), '{}'::json);
end $$;

create or replace function public.host_badges (p_pass text) returns json language plpgsql security definer set search_path = public, extensions as $$
begin
  perform public.adm(p_pass);
  return coalesce((select json_object_agg(username, to_json(badges)) from public.players where not banned and cardinality(coalesce(badges,'{}')) > 0), '{}'::json);
end $$;


-- =====================================================================
-- THE PR FORMULA & ADMIN LOGIC (PROTECTED)
-- =====================================================================
create or replace function public.adm (p_pass text) returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  if coalesce(current_setting('app.panel_ok', true), '') = 'on' then return; end if;
  perform pg_sleep(0.5); raise exception 'BAD_ADMIN';
end $$;

create or replace function public.pr_formula (
  p_avg numeric, p_pr numeric, p_streak int, p_kills int, p_ace int, p_place int, p_mode int
) returns int language plpgsql immutable set search_path = public, extensions as $$
declare v_rp numeric; v_w int; v_k int; v_a int; v_raw numeric; v_bonus int;
begin
  v_rp := greatest(0.5, least(2, greatest(coalesce(p_avg,5000),1) / greatest(coalesce(p_pr,5000),1)));
  v_w  := greatest(0, least(coalesce(p_streak,0), 5));
  v_k  := greatest(0, least(coalesce(p_kills,0), p_mode - 1));
  v_a  := case when coalesce(p_ace,0) > 0 then 1 else 0 end;
  v_raw := floor(20*v_w + 200*v_rp*v_w + 100*v_rp*v_k + 20*v_a + v_a*abs(200*v_rp) - 200/v_rp);
  v_bonus := case when p_place = 1 then 60 when p_place = p_mode then 0 when p_place = p_mode - 1 then 50 else 55 end;
  return greatest(-500, least(1500, v_raw + v_bonus))::int;
end $$;

create or replace function public.pr_game_avg (p_lobby uuid, p_player uuid) returns numeric language sql stable security definer set search_path = public, extensions as $$
  with me as (select count(*) as g from public.lobby_results where lobby_id = p_lobby and player_id = p_player)
  select coalesce(avg(p.pr - coalesce((
      select sum(x.d) from (select r.pr_delta as d, row_number() over (order by r.played_at, r.id) as rn
                            from public.lobby_results r where r.lobby_id = p_lobby and r.player_id = lp.player_id) x
      where x.rn > (select g from me)), 0)), 5000)
  from public.lobby_players lp join public.players p on p.id = lp.player_id
  where lp.lobby_id = p_lobby and lp.picked;
$$;

create or replace function public.pr_delta_for (p_lobby uuid, p_player uuid, p_place int, p_kills int, p_aces int, p_streak int) returns numeric language plpgsql stable security definer set search_path = public, extensions as $$
declare v_mode int; v_pr numeric; v_streak int; v_place int; v_delta int;
begin
  select mode into v_mode from public.lobbies where id = p_lobby;
  select pr, streak into v_pr, v_streak from public.players where id = p_player;
  v_place := greatest(1, least(coalesce(p_place, v_mode), v_mode));
  v_delta := public.pr_formula(public.pr_game_avg(p_lobby, p_player), v_pr, coalesce(p_streak, case when v_place = 1 then v_streak + 1 else 0 end), p_kills, p_aces, v_place, v_mode);
  if v_delta = 0 then v_delta := case when v_place < v_mode then 1 else -1 end; end if;
  return greatest(v_delta, -v_pr);
end $$;

create or replace function public.admin_preview_pr (p_pass text, p_lobby uuid, p_user text, p_place int, p_kills int, p_aces int, p_streak int) returns json language plpgsql security definer set search_path = public, extensions as $$
declare v_id uuid; v_pr numeric; v_d numeric;
begin
  perform public.adm(p_pass);
  select id, pr into v_id, v_pr from public.players where lower(username) = lower(p_user);
  if v_id is null then raise exception 'Player not found.'; end if;
  if not exists (select 1 from public.lobby_players where lobby_id = p_lobby and player_id = v_id and picked) then raise exception 'That player is not in this match.'; end if;
  v_d := public.pr_delta_for(p_lobby, v_id, p_place, p_kills, p_aces, p_streak);
  return json_build_object('delta', v_d, 'pr', v_pr, 'after', v_pr + v_d, 'avg', round(public.pr_game_avg(p_lobby, v_id)));
end $$;

create or replace function public.admin_state (p_pass text) returns json language plpgsql security definer set search_path = public, extensions as $$
begin
  perform public.adm(p_pass);
  return json_build_object('now', now(), 'lobbies', coalesce((select json_agg(x order by x.created_at) from (
    select l.id, l.name, l.mode, l.status, l.starts_at, l.created_at,
      (select coalesce(json_agg(json_build_object('u',p.username,'picked',lp.picked,'spawn',lp.spawn,'pr',p.pr,'streak',p.streak,'tokens',p.tokens,
          'games',(select count(*) from public.lobby_results r where r.lobby_id=l.id and r.player_id=p.id),
          'res',(select row_to_json(r) from public.lobby_results r where r.lobby_id=l.id and r.player_id=p.id order by r.saved_at desc, r.id desc limit 1))
          order by lp.picked desc, p.username),'[]'::json)
        from public.lobby_players lp join public.players p on p.id=lp.player_id where lp.lobby_id=l.id) as players
    from public.lobbies l where l.status <> 'closed') x), '[]'::json));
end $$;

-- Which event is live right now (admin "on" wins, otherwise the most recently started scheduled one).
create or replace function public.active_event () returns text language sql stable security definer set search_path = public, extensions as $$
  select e.key from public.events e
  where case e.mode when 'on' then true when 'off' then false else now() >= e.starts_at and now() < e.ends_at end
  order by (e.mode = 'on') desc, e.starts_at desc limit 1;
$$;

-- Host creates a lobby -> it automatically joins the live event (if any).
create or replace function public.admin_create (p_pass text, p_name text, p_mode int) returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  perform public.adm(p_pass);
  insert into public.lobbies (name, mode, event_key) values (trim(p_name), p_mode, public.active_event());
end $$;

-- Admin: auto = follow schedule | on = unlock now | off = lock.
create or replace function public.admin_set_event (p_pass text, p_key text, p_mode text) returns json language plpgsql security definer set search_path = public, extensions as $$
declare v_name text;
begin
  perform public.adm(p_pass);
  if p_mode is null or p_mode not in ('auto', 'on', 'off') then raise exception 'BAD_MODE'; end if;
  update public.events set mode = p_mode where key = p_key returning name into v_name;
  if v_name is null then raise exception 'EVENT_NOT_FOUND'; end if;
  return json_build_object('event', v_name, 'mode', p_mode);
end $$;

-- Event standings: points = net PR earned in this event's lobbies. Rank by points, wins, kills.
create or replace function public.event_leaderboard (p_token text, p_key text) returns json language plpgsql security definer set search_path = public, extensions as $$
begin
  if public.session_player(p_token) is null then raise exception 'INVALID_SESSION'; end if;
  return coalesce((select json_agg(t order by t.rank) from (
    select row_number() over (order by s.pts desc, s.wins desc, s.kills desc, lower(s.username)) as rank,
           s.username, s.games, s.wins, s.kills, s.aces, s.pts
    from (
      select p.username, count(*)::int as games, (count(*) filter (where r.won))::int as wins,
             coalesce(sum(r.kills), 0)::int as kills, coalesce(sum(r.aces), 0)::int as aces,
             round(coalesce(sum(r.pr_delta), 0))::int as pts
      from public.lobby_results r
      join public.lobbies l on l.id = r.lobby_id
      join public.players p on p.id = r.player_id
      where l.event_key = p_key and not p.banned
      group by p.username) s
    order by 1 limit 50) t), '[]'::json);
end $$;

create or replace function public.admin_set_mode (p_pass text, p_id uuid, p_mode int) returns void language plpgsql security definer set search_path = public, extensions as $$
begin perform public.adm(p_pass);
  update public.lobbies set mode=p_mode where id=p_id and status='open';
  update public.lobby_players set picked=false where lobby_id=p_id;
end $$;

create or replace function public.admin_draw (p_pass text, p_id uuid) returns void language plpgsql security definer set search_path = public, extensions as $$
begin perform public.adm(p_pass);
  update public.lobby_players set picked=false where lobby_id=p_id;
  update public.lobby_players set picked=true where lobby_id=p_id and player_id in (
    select lp.player_id from public.lobby_players lp join public.players p on p.id=lp.player_id
    where lp.lobby_id=p_id order by p.played asc, p.skips desc, random() limit (select mode from public.lobbies where id=p_id));
end $$;

create or replace function public.assign_spawns (p_lobby uuid) returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_mode int; v_spawns text[];
begin
  perform pg_advisory_xact_lock(hashtext(p_lobby::text));
  select mode into v_mode from public.lobbies where id = p_lobby;
  if v_mode is null then return; end if;
  if not exists (select 1 from public.lobby_players where lobby_id = p_lobby and picked and spawn is null) then return; end if;
  v_spawns := case when v_mode = 4 then array['STAIRCASE','HALLWAY','BEDROOM','STUDIO'] else array['STAIRCASE','HALLWAY','BEDROOM'] end;
  update public.lobby_players set spawn = null where lobby_id = p_lobby;
  with pk as (select player_id, row_number() over (order by random()) as rn from public.lobby_players where lobby_id = p_lobby and picked),
       sp as (select u.val as s, row_number() over (order by random()) as rn from unnest(v_spawns) as u(val))
  update public.lobby_players lp set spawn = sp.s from pk join sp on sp.rn = pk.rn where lp.lobby_id = p_lobby and lp.player_id = pk.player_id;
end $$;

create or replace function public.admin_start (p_pass text, p_id uuid) returns void language plpgsql security definer set search_path = public, extensions as $$
begin perform public.adm(p_pass);
  if not exists (select 1 from public.lobbies where id=p_id and status='open') then raise exception 'Lobby is not open.'; end if;
  if not exists (select 1 from public.lobby_players where lobby_id=p_id) then raise exception 'Nobody has joined yet.'; end if;
  if not exists (select 1 from public.lobby_players where lobby_id=p_id and picked) then perform public.admin_draw(p_pass, p_id); end if;
  update public.players set played=played+1, skips=0 where id in (select player_id from public.lobby_players where lobby_id=p_id and picked);
  update public.players set skips=skips+1 where id in (select player_id from public.lobby_players where lobby_id=p_id and not picked);
  perform public.assign_spawns(p_id);
  update public.lobbies set status='started', starts_at = now() + interval '60 seconds' where id=p_id;
end $$;

create or replace function public.admin_close (p_pass text, p_id uuid) returns void language plpgsql security definer set search_path = public, extensions as $$
begin perform public.adm(p_pass); update public.lobbies set status='closed' where id=p_id; end $$;

create or replace function public.admin_save_result (p_pass text, p_lobby uuid, p_user text, p_place int, p_kills int, p_deaths int, p_aces int, p_streak int, p_tokens int default 0) returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_id uuid; v_pl public.players; v_mode int; v_place int; v_won boolean; v_k int; v_d int; v_a int; v_before int; v_streak int; v_delta numeric; v_new numeric; v_t int; v_newtok int;
begin
  perform public.adm(p_pass);
  select mode into v_mode from public.lobbies where id=p_lobby;
  if v_mode is null then raise exception 'Lobby not found.'; end if;
  select id into v_id from public.players where lower(username)=lower(p_user);
  if v_id is null then raise exception 'Player not found.'; end if;
  if not exists (select 1 from public.lobby_players where lobby_id=p_lobby and player_id=v_id and picked) then raise exception 'That player is not in this match.'; end if;
  v_place := greatest(1, least(coalesce(p_place, v_mode), v_mode));
  v_won := (v_place = 1);
  v_k := greatest(0, least(coalesce(p_kills,0), 200));
  v_d := greatest(0, least(coalesce(p_deaths,0), 200));
  v_a := greatest(0, least(coalesce(p_aces,0), 50));

  select * into v_pl from public.players where id=v_id;
  v_before := v_pl.streak;
  v_streak := greatest(0, coalesce(p_streak, case when v_won then v_before + 1 else 0 end));
  v_delta  := public.pr_delta_for(p_lobby, v_id, v_place, v_k, v_a, v_streak);
  v_new    := greatest(0, round(v_pl.pr + v_delta, 2));

  v_newtok := greatest(0, v_pl.tokens + greatest(-1000000, least(coalesce(p_tokens,0), 1000000)));
  v_t := v_newtok - v_pl.tokens;

  insert into public.lobby_results (lobby_id, player_id, won, place, kills, deaths, aces, streak_before, pr_delta, tokens, saved_at, played_at)
  values (p_lobby, v_id, v_won, v_place, v_k, v_d, v_a, v_before, v_new - v_pl.pr, v_t, now(), now());

  update public.players set wins = wins + case when v_won then 1 else 0 end, losses = losses + case when v_won then 0 else 1 end,
    kills = kills + v_k, deaths = deaths + v_d, aces = aces + v_a, streak = v_streak, pr = v_new, tokens = v_newtok
  where id = v_id;
end $$;

create or replace function public.admin_undo_result (p_pass text, p_lobby uuid, p_user text) returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_id uuid; v_r public.lobby_results;
begin
  perform public.adm(p_pass);
  select id into v_id from public.players where lower(username)=lower(p_user);
  select * into v_r from public.lobby_results where lobby_id=p_lobby and player_id=v_id order by saved_at desc, id desc limit 1;
  if not found then raise exception 'Nothing to undo.'; end if;
  delete from public.lobby_results where id = v_r.id;
  update public.players set
    wins = wins - case when v_r.won then 1 else 0 end, losses = losses - case when v_r.won then 0 else 1 end,
    kills = kills - v_r.kills, deaths = deaths - v_r.deaths, aces = aces - v_r.aces,
    pr = greatest(0, pr - v_r.pr_delta), streak = v_r.streak_before, tokens = greatest(0, tokens - v_r.tokens)
  where id = v_id;
end $$;

create or replace function public.report_player (p_token text, p_username text, p_reason text) returns void language plpgsql security definer set search_path = public, extensions as $$
declare pid uuid := public.session_player(p_token); tid uuid;
begin
  if pid is null then raise exception 'INVALID_SESSION'; end if;
  select id into tid from public.players where lower(username)=lower(p_username) and not banned;
  if tid is null then raise exception 'Player not found.'; end if;
  if tid = pid then raise exception 'You can''t report yourself.'; end if;
  if char_length(trim(coalesce(p_reason,''))) < 5 then raise exception 'Please write a reason (at least 5 characters).'; end if;
  if exists (select 1 from public.reports where reporter_id=pid and reported_id=tid and status='open') then raise exception 'You already have an open report on this player.'; end if;
  if (select count(*) from public.reports where reporter_id=pid and created_at > now() - interval '1 hour') >= 5 then raise exception 'Too many reports. Try again later.'; end if;
  insert into public.reports (reporter_id, reported_id, reason) values (pid, tid, left(trim(p_reason), 500));
end $$;

create or replace function public.player_history (p_token text, p_username text) returns json language plpgsql security definer set search_path = public, extensions as $$
declare tid uuid; v_pr numeric; v_total numeric;
begin
  if public.session_player(p_token) is null then raise exception 'INVALID_SESSION'; end if;
  select id, pr into tid, v_pr from public.players where lower(username)=lower(p_username) and not banned;
  if tid is null then raise exception 'Player not found.'; end if;
  select coalesce(sum(pr_delta),0) into v_total from public.lobby_results where player_id=tid;
  return json_build_object(
    'start', v_pr - v_total,
    'places', (select json_build_object('p1', count(*) filter (where coalesce(place, case when won then 1 end) = 1),
        'p2', count(*) filter (where place = 2), 'p3', count(*) filter (where place = 3), 'p4', count(*) filter (where place = 4))
      from public.lobby_results where player_id=tid),
    'matches', coalesce((select json_agg(m order by m."at" desc, m.id desc) from (
      select r.id, l.name as lobby, coalesce(r.place, case when r.won then 1 end) as place, r.won, r.kills, r.deaths, r.aces,
             r.pr_delta as delta, r.tokens, row_number() over (partition by r.lobby_id order by r.played_at, r.id) as g,
             round(v_pr - v_total + sum(r.pr_delta) over (order by r.played_at, r.id), 2) as pr_after, r.played_at as "at"
      from public.lobby_results r join public.lobbies l on l.id=r.lobby_id
      where r.player_id=tid order by r.played_at desc, r.id desc limit 50) m), '[]'::json));
end $$;

create or replace function public.admin_reports (p_pass text) returns json language plpgsql security definer set search_path = public, extensions as $$
begin
  perform public.adm(p_pass);
  return coalesce((select json_agg(x order by x.created_at) from (
    select r.id, r.reason, r.created_at, rp.username as reporter, rd.username as reported,
      (select count(*) from public.reports o where o.reported_id=r.reported_id and o.status='open') as total
    from public.reports r join public.players rp on rp.id=r.reporter_id join public.players rd on rd.id=r.reported_id
    where r.status='open') x), '[]'::json);
end $$;

create or replace function public.admin_resolve_report (p_pass text, p_id uuid, p_ban boolean) returns void language plpgsql security definer set search_path = public, extensions as $$
declare tid uuid;
begin
  perform public.adm(p_pass);
  select reported_id into tid from public.reports where id=p_id;
  if tid is null then raise exception 'Report not found.'; end if;
  if p_ban then
    update public.players set banned=true where id=tid;
    delete from public.sessions where player_id=tid;
    delete from public.lobby_players where player_id=tid and lobby_id in (select id from public.lobbies where status='open');
    update public.reports set status='banned' where reported_id=tid and status='open';
  else
    update public.reports set status='dismissed' where id=p_id;
  end if;
end $$;

create or replace function public.admin_notify (p_pass text, p_title text, p_body text, p_to text default null) returns void language plpgsql security definer set search_path = public, extensions as $$
declare tid uuid; v_title text := trim(coalesce(p_title,'')); v_body text := trim(coalesce(p_body,'')); v_to text := trim(coalesce(p_to,''));
begin
  perform public.adm(p_pass);
  if char_length(v_title) < 1 then raise exception 'Give the notification a title.'; end if;
  if char_length(v_title) > 80 then raise exception 'Title is too long (80 characters max).'; end if;
  if char_length(v_body) < 1 then raise exception 'Write a message first.'; end if;
  if char_length(v_body) > 500 then raise exception 'Message is too long (500 characters max).'; end if;
  if v_to <> '' then
    select id into tid from public.players where lower(username) = lower(v_to) and not banned;
    if tid is null then raise exception 'Player "%" not found.', v_to; end if;
  end if;
  insert into public.notifications (to_id, title, body) values (tid, v_title, v_body);
end $$;

create or replace function public.admin_notifications (p_pass text) returns json language plpgsql security definer set search_path = public, extensions as $$
begin
  perform public.adm(p_pass);
  return coalesce((select json_agg(x order by x.created_at desc) from (
    select n.id, n.title, n.body, n.created_at, p.username as to_user,
           (select count(*) from public.notification_reads r where r.notification_id = n.id) as reads
    from public.notifications n left join public.players p on p.id = n.to_id
    order by n.created_at desc limit 30) x), '[]'::json);
end $$;

create or replace function public.admin_delete_notification (p_pass text, p_id uuid) returns void language plpgsql security definer set search_path = public, extensions as $$
begin perform public.adm(p_pass); delete from public.notifications where id = p_id; end $$;

create or replace function public.admin_knives (p_pass text) returns json language plpgsql security definer set search_path = public, extensions as $$
begin
  perform public.adm(p_pass);
  return coalesce((select json_agg(x order by x.sort) from (
    select k.key, k.name, k.image, k.multi, k.sort,
      coalesce((select json_agg(json_build_object('u', o.username, 'n', o.n) order by o.username)
                from (select p.username, count(*) as n from public.player_items pi
                      join public.players p on p.id = pi.player_id where pi.item = k.key group by p.username) o), '[]'::json) as owners
    from public.knives k) x), '[]'::json);
end $$;

create or replace function public.admin_give_knife (p_pass text, p_user text, p_key text, p_move boolean default false) returns json language plpgsql security definer set search_path = public, extensions as $$
declare pid uuid; k public.knives; uname text;
begin
  perform public.adm(p_pass);
  select id, username into pid, uname from public.players where lower(username) = lower(trim(coalesce(p_user,''))) and not banned;
  if pid is null then raise exception 'PLAYER_NOT_FOUND'; end if;
  select * into k from public.knives where key = p_key;
  if not found then raise exception 'UNKNOWN_KNIFE'; end if;
  if not k.multi and exists (select 1 from public.player_items where player_id = pid and item = p_key) then raise exception 'ALREADY_HAS'; end if;
  insert into public.player_items (player_id, item, source) values (pid, p_key, 'host');
  insert into public.notifications (to_id, title, body) values (pid, 'You got a new knife!', 'The host gave you the ' || k.name || '. Find it in your inventory (Store tab).');
  return json_build_object('player', uname, 'knife', k.name);
end $$;

create or replace function public.admin_take_knife (p_pass text, p_user text, p_key text) returns json language plpgsql security definer set search_path = public, extensions as $$
declare rid uuid; uname text; kname text;
begin
  perform public.adm(p_pass);
  select pi.id, p.username into rid, uname from public.player_items pi join public.players p on p.id = pi.player_id
    where lower(p.username) = lower(trim(coalesce(p_user,''))) and pi.item = p_key limit 1;
  if rid is null then raise exception 'NOT_OWNED'; end if;
  delete from public.player_items where id = rid;
  select name into kname from public.knives where key = p_key;
  return json_build_object('player', uname, 'knife', coalesce(kname, p_key));
end $$;

create or replace function public.admin_set_badge (p_pass text, p_user text, p_badge text, p_on boolean default true) returns json language plpgsql security definer set search_path = public, extensions as $$
declare pid uuid; uname text;
begin
  perform public.adm(p_pass);
  if p_badge not in ('host','dev','youtuber','twitch') then raise exception 'BAD_BADGE'; end if;
  select id, username into pid, uname from public.players where lower(username) = lower(trim(coalesce(p_user,''))) and not banned;
  if pid is null then raise exception 'PLAYER_NOT_FOUND'; end if;
  if p_on then update public.players set badges = array_append(array_remove(coalesce(badges,'{}'), p_badge), p_badge) where id = pid;
  else update public.players set badges = array_remove(coalesce(badges,'{}'), p_badge) where id = pid; end if;
  return json_build_object('player', uname, 'badge', p_badge, 'on', p_on);
end $$;

create or replace function public.admin_badges (p_pass text) returns json language plpgsql security definer set search_path = public, extensions as $$
begin
  perform public.adm(p_pass);
  return coalesce((select json_agg(x order by lower(x.u)) from (
    select username as u, to_json(badges) as badges from public.players where cardinality(coalesce(badges,'{}')) > 0) x), '[]'::json);
end $$;

create or replace function public.admin_give_tokens (p_pass text, p_user text, p_amount int) returns json language plpgsql security definer set search_path = public, extensions as $$
declare pid uuid; uname text; v_left int;
begin
  perform public.adm(p_pass);
  select id, username into pid, uname from public.players where lower(username) = lower(trim(coalesce(p_user,''))) and not banned;
  if pid is null then raise exception 'PLAYER_NOT_FOUND'; end if;
  update public.players set tokens = greatest(0, tokens + greatest(-1000000, least(coalesce(p_amount,0), 1000000)))
    where id = pid returning tokens into v_left;
  return json_build_object('player', uname, 'tokens', v_left);
end $$;

create or replace function public.admin_set_ban (p_pass text, p_user text, p_banned boolean) returns json language plpgsql security definer set search_path = public, extensions as $$
declare pid uuid; uname text;
begin
  perform public.adm(p_pass);
  select id, username into pid, uname from public.players where lower(username) = lower(trim(coalesce(p_user,'')));
  if pid is null then raise exception 'PLAYER_NOT_FOUND'; end if;
  update public.players set banned = p_banned where id = pid;
  if p_banned then
    delete from public.sessions where player_id = pid;
    delete from public.lobby_players where player_id = pid and lobby_id in (select id from public.lobbies where status = 'open');
  end if;
  return json_build_object('player', uname, 'banned', p_banned);
end $$;

create or replace function public.admin_roles (p_pass text) returns json language plpgsql security definer set search_path = public, extensions as $$
begin
  perform public.adm(p_pass);
  return json_build_object(
    'defs', coalesce((select json_agg(json_build_object('key', r.key, 'name', r.name) order by r.sort) from public.roles r), '[]'::json),
    'holders', coalesce((select json_agg(x order by lower(x.u)) from (
        select p.username as u, json_agg(pr.role_key order by r.sort) as roles
        from public.player_roles pr join public.roles r on r.key = pr.role_key
        join public.players p on p.id = pr.player_id group by p.username) x), '[]'::json));
end $$;

create or replace function public.admin_set_role (p_pass text, p_user text, p_role text, p_on boolean default true) returns json language plpgsql security definer set search_path = public, extensions as $$
declare pid uuid; uname text;
begin
  perform public.adm(p_pass);
  if not exists (select 1 from public.roles where key = p_role) then raise exception 'BAD_ROLE'; end if;
  select id, username into pid, uname from public.players where lower(username) = lower(trim(coalesce(p_user,''))) and not banned;
  if pid is null then raise exception 'PLAYER_NOT_FOUND'; end if;
  if p_on then
    if p_role = 'tournament_winner_1x' then delete from public.player_roles where player_id = pid and role_key = 'tournament_winner_2x'; end if;
    if p_role = 'tournament_winner_2x' then delete from public.player_roles where player_id = pid and role_key = 'tournament_winner_1x'; end if;
    insert into public.player_roles (player_id, role_key) values (pid, p_role) on conflict do nothing;
  else
    delete from public.player_roles where player_id = pid and role_key = p_role;
  end if;
  return json_build_object('player', uname, 'role', p_role, 'on', p_on);
end $$;

-- ---------- 9b. ADMIN: CREATE / EDIT / DELETE EVENTS ----------
-- All of these only run through panel_call from the Host panel (the server checks the session + HOST badge).

-- every event (including old ones) with a quick count of lobbies + players
create or replace function public.admin_events (p_pass text) returns json language plpgsql security definer set search_path = public, extensions as $$
begin
  perform public.adm(p_pass);
  return coalesce((select json_agg(json_build_object(
      'key', e.key, 'name', e.name, 'image', e.image, 'starts_at', e.starts_at, 'ends_at', e.ends_at,
      'mode', e.mode, 'blurb', e.blurb, 'format', e.format, 'rules', e.rules, 'prizes', e.prizes,
      'lobbies', (select count(*) from public.lobbies l where l.event_key = e.key),
      'players', (select count(distinct r.player_id) from public.lobby_results r join public.lobbies l on l.id = r.lobby_id where l.event_key = e.key))
    order by e.starts_at desc) from public.events e), '[]'::json);
end $$;

-- no p_key = create a new event (its key is made from the name); with p_key = edit that event
create or replace function public.admin_save_event (
  p_pass text, p_key text default null, p_name text default null, p_image text default null,
  p_starts_at timestamptz default null, p_ends_at timestamptz default null, p_mode text default 'auto',
  p_blurb text default null, p_format text default null, p_rules jsonb default '[]'::jsonb, p_prizes jsonb default '[]'::jsonb
) returns json language plpgsql security definer set search_path = public, extensions as $$
declare v_key text; v_base text; v_n int := 1; v_name text := btrim(coalesce(p_name, ''));
        v_img text := nullif(btrim(coalesce(p_image, '')), ''); v_rules jsonb; v_prizes jsonb;
begin
  perform public.adm(p_pass);
  if char_length(v_name) < 1 or char_length(v_name) > 60 then raise exception 'BAD_NAME'; end if;
  if p_starts_at is null or p_ends_at is null or p_ends_at <= p_starts_at then raise exception 'BAD_DATES'; end if;
  if p_mode is null or p_mode not in ('auto', 'on', 'off') then raise exception 'BAD_MODE'; end if;
  -- image: a file in assets/ (e.g. jon_taffer_event.png) or a full https:// link
  if v_img is not null and (char_length(v_img) > 400
      or not (v_img ~ '^[A-Za-z0-9_./-]+$' and v_img !~ '\.\.' or v_img ~ '^https://[^\s"''<>]+$')) then
    raise exception 'BAD_IMAGE'; end if;
  if char_length(coalesce(p_blurb, '')) > 600 or char_length(coalesce(p_format, '')) > 60 then raise exception 'TOO_LONG'; end if;

  -- rules: up to 20 lines of text
  if jsonb_typeof(coalesce(p_rules, '[]'::jsonb)) <> 'array' then raise exception 'BAD_RULES'; end if;
  select coalesce(jsonb_agg(left(btrim(x), 300)), '[]'::jsonb) into v_rules
    from jsonb_array_elements_text(coalesce(p_rules, '[]'::jsonb)) x where btrim(x) <> '';
  if jsonb_array_length(v_rules) > 20 then raise exception 'BAD_RULES'; end if;

  -- prizes: up to 10 of {"place": "1st", "prize": "..."}
  if jsonb_typeof(coalesce(p_prizes, '[]'::jsonb)) <> 'array' then raise exception 'BAD_PRIZES'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('place', left(btrim(coalesce(x->>'place', '')), 20),
                                               'prize', left(btrim(coalesce(x->>'prize', '')), 120))), '[]'::jsonb)
    into v_prizes from jsonb_array_elements(coalesce(p_prizes, '[]'::jsonb)) x
   where jsonb_typeof(x) = 'object' and btrim(coalesce(x->>'prize', '')) <> '';
  if jsonb_array_length(v_prizes) > 10 then raise exception 'BAD_PRIZES'; end if;

  if p_key is null or btrim(p_key) = '' then
    v_base := left(trim(both '_' from regexp_replace(lower(v_name), '[^a-z0-9]+', '_', 'g')), 40);
    if v_base = '' then v_base := 'event'; end if;
    v_key := v_base;
    while exists (select 1 from public.events where key = v_key) loop
      v_n := v_n + 1; v_key := v_base || '_' || v_n;
    end loop;
    insert into public.events (key, name, image, starts_at, ends_at, mode, blurb, format, rules, prizes, sort)
    values (v_key, v_name, v_img, p_starts_at, p_ends_at, p_mode,
            nullif(btrim(coalesce(p_blurb, '')), ''), nullif(btrim(coalesce(p_format, '')), ''), v_rules, v_prizes,
            coalesce((select max(sort) from public.events), 0) + 1);
    return json_build_object('key', v_key, 'name', v_name, 'created', true);
  end if;

  update public.events set name = v_name, image = v_img, starts_at = p_starts_at, ends_at = p_ends_at, mode = p_mode,
         blurb = nullif(btrim(coalesce(p_blurb, '')), ''), format = nullif(btrim(coalesce(p_format, '')), ''),
         rules = v_rules, prizes = v_prizes
   where key = p_key returning key into v_key;
  if v_key is null then raise exception 'EVENT_NOT_FOUND'; end if;
  return json_build_object('key', v_key, 'name', v_name, 'created', false);
end $$;

-- deleting an event keeps its lobbies and games (they just stop being tagged with the event)
create or replace function public.admin_delete_event (p_pass text, p_key text) returns json language plpgsql security definer set search_path = public, extensions as $$
declare v_name text;
begin
  perform public.adm(p_pass);
  delete from public.events where key = p_key returning name into v_name;
  if v_name is null then raise exception 'EVENT_NOT_FOUND'; end if;
  return json_build_object('event', v_name, 'deleted', true);
end $$;


-- ---------- 9c. PLAYER INSIGHTS (Stats page) ----------
-- Records, form, placement spread, peak PR, longest streak, head-to-head rivals and more.
create or replace function public.player_insights (p_token text, p_username text) returns json language plpgsql stable security definer set search_path = public, extensions as $$
declare p public.players%rowtype; v_start numeric; v_res json;
begin
  if public.session_player(p_token) is null then raise exception 'INVALID_SESSION'; end if;
  select * into p from public.players where lower(username) = lower(p_username) and not banned;
  if p.id is null then raise exception 'Player not found.'; end if;
  v_start := p.pr - coalesce((select sum(pr_delta) from public.lobby_results where player_id = p.id), 0);

  with g as (   -- every saved game, numbered inside its lobby (the same roster plays every game of a lobby)
    select r.*, l.name as lobby, l.event_key,
           row_number() over (partition by r.lobby_id, r.player_id order by r.played_at, r.id) as gn
    from public.lobby_results r join public.lobbies l on l.id = r.lobby_id
  ), mine as (
    select g.*, coalesce(g.place, case when g.won then 1 end) as plc,
           round(v_start + sum(g.pr_delta) over (order by g.played_at, g.id), 2) as pr_after,
           row_number() over (order by g.played_at, g.id) as seq
    from g where g.player_id = p.id
  ), streaks as (
    select count(*) as len from (select seq - row_number() over (order by seq) as grp from mine where won) s group by grp
  ), opp as (   -- head to head vs everyone who played the same game
    select o.player_id, count(*) as games,
           count(*) filter (where coalesce(m.plc, 9) < coalesce(o.place, case when o.won then 1 end, 9)) as beat,
           count(*) filter (where coalesce(m.plc, 9) > coalesce(o.place, case when o.won then 1 end, 9)) as lost
    from mine m join g o on o.lobby_id = m.lobby_id and o.gn = m.gn and o.player_id <> p.id
    group by o.player_id
  )
  select json_build_object(
    'username', p.username,
    'joined', p.created_at,
    'pr', p.pr,
    'rank', (select count(*) + 1 from public.players x where not x.banned and x.pr > p.pr),
    'of', (select count(*) from public.players x where not x.banned),
    'totals', json_build_object('played', p.played, 'wins', p.wins, 'losses', p.losses,
               'kills', p.kills, 'deaths', p.deaths, 'aces', p.aces, 'streak', p.streak),
    'games', (select count(*) from mine),
    'places', (select json_build_object('p1', count(*) filter (where plc = 1), 'p2', count(*) filter (where plc = 2),
                                        'p3', count(*) filter (where plc = 3), 'p4', count(*) filter (where plc = 4)) from mine),
    'avg_place', (select round(avg(plc)::numeric, 2) from mine where plc is not null),
    'peak_pr', greatest(v_start, coalesce((select max(pr_after) from mine), v_start), p.pr),
    'low_pr', least(v_start, coalesce((select min(pr_after) from mine), v_start), p.pr),
    'best_streak', greatest(coalesce((select max(len) from streaks), 0), p.streak),
    'best_game', (select json_build_object('kills', kills, 'deaths', deaths, 'aces', aces, 'lobby', lobby, 'at', played_at)
                  from mine order by kills desc, aces desc, deaths asc, played_at desc limit 1),
    'best_gain', (select json_build_object('delta', pr_delta, 'lobby', lobby, 'at', played_at)
                  from mine where pr_delta > 0 order by pr_delta desc limit 1),
    'worst_loss', (select json_build_object('delta', pr_delta, 'lobby', lobby, 'at', played_at)
                   from mine where pr_delta < 0 order by pr_delta asc limit 1),
    'tokens_won', (select coalesce(sum(tokens), 0) from mine where tokens > 0),
    'events', (select count(distinct event_key) from mine where event_key is not null),
    'lobbies', (select count(distinct lobby_id) from mine),
    'flawless', (select count(*) from mine where deaths = 0),
    'ace_games', (select count(*) from mine where aces > 0),
    'form', coalesce((select json_agg(json_build_object('won', f.won, 'place', f.plc, 'delta', f.pr_delta, 'lobby', f.lobby, 'at', f.played_at) order by f.seq desc)
                      from (select * from mine order by seq desc limit 10) f), '[]'::json),
    'day', (select to_char(played_at at time zone 'America/Chicago', 'FMDay') from mine group by 1 order by count(*) desc, 1 limit 1),
    'rivals', coalesce((select json_agg(json_build_object('u', x.username, 'games', o.games, 'beat', o.beat, 'lost', o.lost)
                         order by o.games desc, o.lost desc, lower(x.username))
                       from opp o join public.players x on x.id = o.player_id where not x.banned), '[]'::json)
  ) into v_res;
  return v_res;
end $$;


-- ---------- 10. PANEL GATEWAY (Badge Security) ----------
-- Replaces old password setup entirely. Allows Admin/Host sites to talk securely 
-- without hardcoded passwords by verifying login sessions and badges.
create or replace function public.panel_call(
  p_token text,
  p_panel text,
  p_fn    text,
  p_args  jsonb default '{}'::jsonb
) returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_need    text;
  v_allowed text[];
  v_pid     uuid;
  v_user    text;
  v_badges  text[];
  v_rt      regtype;
  v_k       text;
  v_v       jsonb;
  v_args    text;
  v_res     jsonb;
begin
  if p_panel = 'dev' then
    v_need := 'dev';
    v_allowed := array[
      'admin_badges','admin_reports','admin_resolve_report','admin_give_tokens',
      'admin_set_ban','admin_set_badge','admin_roles','admin_set_role',
      'admin_knives','admin_give_knife','admin_take_knife'
    ];
  elsif p_panel = 'host' then
    v_need := 'host';
    v_allowed := array[
      'admin_state','admin_create','admin_set_mode','admin_draw','admin_start',
      'admin_close','admin_preview_pr','admin_save_result','admin_undo_result',
      'admin_notifications','admin_delete_notification','admin_notify',
      -- events are run by hosts
      'admin_events','admin_save_event','admin_delete_event','admin_set_event'
    ];
  else
    raise exception 'FORBIDDEN';
  end if;

  if p_fn is null or not (p_fn = any(v_allowed)) then
    raise exception 'FORBIDDEN';
  end if;

  v_pid := public.session_player(p_token);
  if v_pid is null then raise exception 'INVALID_SESSION'; end if;

  select badges into v_badges from public.players where id = v_pid;
  if v_badges is null or not (v_need = any(v_badges)) then
    raise exception 'FORBIDDEN';
  end if;

  v_args := 'p_pass => ''''';
  for v_k, v_v in select key, value from jsonb_each(coalesce(p_args, '{}'::jsonb)) loop
    if v_k !~ '^p_[a-z0-9_]{1,40}$' or v_k = 'p_pass' then
      raise exception 'BAD_ARGS';
    end if;
    if jsonb_typeof(v_v) = 'null' then
      v_args := v_args || format(', %I => NULL', v_k);
    else
      v_args := v_args || format(', %I => %L', v_k, v_v #>> '{}');
    end if;
  end loop;

  select p.prorettype::regtype into v_rt
    from pg_proc p
   where p.proname = p_fn and p.pronamespace = 'public'::regnamespace
   limit 1;
  if v_rt is null then raise exception 'FORBIDDEN'; end if;

  perform set_config('app.panel_ok', 'on', true);
  if v_rt = 'void'::regtype then
    execute format('select public.%I(%s)', p_fn, v_args);
    v_res := null;
  else
    execute format('select to_jsonb(public.%I(%s))', p_fn, v_args) into v_res;
  end if;
  perform set_config('app.panel_ok', 'off', true);
  
  return v_res;
end;
$$;

-- ---------- 10b. WATCH-AN-AD REWARD ----------
-- Videos live at assets/ads/<file>. 'seconds' must match the real video length (all three are 20s).
create table if not exists public.ads (
  id text primary key,
  file text not null check (file ~ '^[A-Za-z0-9_.-]+\.mp4$'),
  seconds int not null check (seconds between 1 and 600),
  active boolean not null default true
);
insert into public.ads (id, file, seconds) values ('ad1','ad1.mp4',20), ('ad2','ad2.mp4',20), ('ad3','ad3.mp4',20)
on conflict (id) do update set file = excluded.file, seconds = excluded.seconds;

create table if not exists public.ad_views (
  id uuid primary key default gen_random_uuid(),
  player_id uuid not null references public.players(id) on delete cascade,
  ad_id text not null references public.ads(id),
  started_at timestamptz not null default now(),
  claimed_at timestamptz
);
create index if not exists ad_views_player_idx on public.ad_views (player_id, started_at desc);
alter table public.ads enable row level security;
alter table public.ad_views enable row level security;
revoke all on public.ads, public.ad_views from anon, authenticated;

-- One claimed ad per player per day (resets at midnight Central, same as the daily chest).
create or replace function public.ad_claimed_today (p_player uuid) returns boolean language sql stable security definer set search_path = public, extensions as $$
  select exists (select 1 from public.ad_views
                 where player_id = p_player and claimed_at is not null
                   and (claimed_at at time zone 'America/Chicago')::date = public.chest_today());
$$;

-- Start: picks a random ad, voids any older unclaimed view, stamps the start time on the server.
create or replace function public.start_ad (p_token text) returns json language plpgsql security definer set search_path = public, extensions as $$
declare pid uuid := public.session_player(p_token); v_ad public.ads; v_id uuid;
begin
  if pid is null then raise exception 'INVALID_SESSION'; end if;
  perform 1 from public.players where id = pid for update;      -- serialise per player
  if public.ad_claimed_today(pid) then raise exception 'AD_LIMIT'; end if;
  select * into v_ad from public.ads where active order by random() limit 1;
  if v_ad.id is null then raise exception 'NO_ADS'; end if;
  delete from public.ad_views where player_id = pid and claimed_at is null;
  insert into public.ad_views (player_id, ad_id) values (pid, v_ad.id) returning id into v_id;
  return json_build_object('view', v_id, 'file', v_ad.file, 'seconds', v_ad.seconds, 'reward', 100);
end $$;

-- Claim: pays 100 tokens once, only if the full ad length has passed on the server clock.
create or replace function public.claim_ad (p_token text, p_view uuid) returns json language plpgsql security definer set search_path = public, extensions as $$
declare pid uuid := public.session_player(p_token); v public.ad_views; v_secs int; v_left int; v_reward int := 100;
begin
  if pid is null then raise exception 'INVALID_SESSION'; end if;
  perform 1 from public.players where id = pid for update;
  select * into v from public.ad_views where id = p_view and player_id = pid for update;
  if v.id is null then raise exception 'AD_INVALID'; end if;
  if v.claimed_at is not null then raise exception 'AD_CLAIMED'; end if;
  -- two browsers watching at the same time: only the first claim of the day pays
  if public.ad_claimed_today(pid) then raise exception 'AD_LIMIT'; end if;
  select seconds into v_secs from public.ads where id = v.ad_id;
  if now() < v.started_at + (v_secs - 1.5) * interval '1 second' then raise exception 'AD_TOO_EARLY'; end if;
  if now() > v.started_at + interval '15 minutes' then raise exception 'AD_EXPIRED'; end if;
  update public.ad_views set claimed_at = now() where id = v.id and claimed_at is null;
  update public.players set tokens = tokens + v_reward where id = pid returning tokens into v_left;
  return json_build_object('amount', v_reward, 'tokens', v_left, 'next_at', public.chest_next_reset());
end $$;

revoke all on function public.start_ad (text), public.claim_ad (text, uuid) from public;
grant execute on function public.start_ad (text), public.claim_ad (text, uuid) to anon, authenticated;

-- ---------- 11. APPLY PERMISSIONS ----------
revoke all on function public.make_session (uuid), public.session_player (text), public.adm (text), public.assign_spawns (uuid), public.notif_unread_count (uuid), public.chest_today (), public.chest_next_reset (), public.pr_formula (numeric, numeric, int, int, int, int, int), public.pr_game_avg (uuid, uuid), public.pr_delta_for (uuid, uuid, int, int, int, int), public.active_event () from public, anon, authenticated;

revoke all on function public.username_available (text), public.signup (text, text), public.login (text, text), public.me (text), public.logout (text), public.update_profile (text, text), public.set_avatar (text, text), public.get_leaderboard (text), public.list_players (text, text), public.game_state (text), public.join_lobby (text, uuid), public.leave_lobby (text, uuid), public.admin_state (text), public.admin_create (text, text, int), public.admin_set_mode (text, uuid, int), public.admin_draw (text, uuid), public.admin_start (text, uuid), public.admin_close (text, uuid), public.admin_save_result (text, uuid, text, int, int, int, int, int, int), public.admin_undo_result (text, uuid, text), public.admin_preview_pr (text, uuid, text, int, int, int, int), public.report_player (text, text, text), public.player_history (text, text), public.my_items (text), public.player_inventory (text, text), public.buy_item (text, text), public.open_case (text), public.avatars_for (text, text[]), public.sell_item (text, text), public.send_message (text, text, text), public.inbox (text), public.messages_read (text), public.delete_message (text, uuid), public.my_notifications (text), public.notifications_read (text), public.open_daily_chest (text), public.admin_notify (text, text, text, text), public.admin_notifications (text), public.admin_delete_notification (text, uuid), public.admin_reports (text), public.admin_resolve_report (text, uuid, boolean), public.admin_knives (text), public.admin_give_knife (text, text, text, boolean), public.admin_take_knife (text, text, text), public.get_badges (text), public.host_badges (text), public.admin_badges (text), public.admin_set_badge (text, text, text, boolean), public.get_roles (text), public.admin_roles (text), public.admin_set_role (text, text, text, boolean), public.admin_give_tokens (text, text, int), public.admin_set_ban (text, text, boolean), public.admin_set_event (text, text, text), public.event_leaderboard (text, text), public.panel_call(text, text, text, jsonb) from public;

grant execute on function public.username_available (text), public.signup (text, text), public.login (text, text), public.me (text), public.logout (text), public.update_profile (text, text), public.set_avatar (text, text), public.get_leaderboard (text), public.list_players (text, text), public.game_state (text), public.join_lobby (text, uuid), public.leave_lobby (text, uuid), public.report_player (text, text, text), public.player_history (text, text), public.my_items (text), public.player_inventory (text, text), public.buy_item (text, text), public.open_case (text), public.avatars_for (text, text[]), public.sell_item (text, text), public.send_message (text, text, text), public.inbox (text), public.messages_read (text), public.delete_message (text, uuid), public.my_notifications (text), public.notifications_read (text), public.open_daily_chest (text), public.get_badges (text), public.get_roles (text), public.event_leaderboard (text, text), public.panel_call(text, text, text, jsonb) to anon, authenticated;

-- ---------- 11b. PERMISSIONS FOR EVENTS, INSIGHTS, ADS ----------
-- internal helpers + admin calls: not callable from the website directly (only through panel_call)
revoke all on function public.ad_claimed_today (uuid) from public, anon, authenticated;
revoke all on function public.admin_events (text) from public, anon, authenticated;
revoke all on function public.admin_save_event (text, text, text, text, timestamptz, timestamptz, text, text, text, jsonb, jsonb) from public, anon, authenticated;
revoke all on function public.admin_delete_event (text, text) from public, anon, authenticated;

-- player-facing calls
revoke all on function public.player_insights (text, text), public.game_state (text), public.start_ad (text), public.claim_ad (text, uuid), public.panel_call (text, text, text, jsonb) from public;
grant execute on function public.player_insights (text, text), public.game_state (text), public.start_ad (text), public.claim_ad (text, uuid), public.panel_call (text, text, text, jsonb) to anon, authenticated;

-- ---------- 12. ADMIN TOOLS (Private SQL Editor Schemas) ----------
create schema if not exists admin;

create or replace function admin.record_result (p_username text, p_won boolean, p_kills int, p_deaths int, p_aces int default 0) returns void language sql as $$
  update public.players set wins = wins + case when p_won then 1 else 0 end, losses = losses + case when p_won then 0 else 1 end, streak = case when p_won then streak + 1 else 0 end, kills = kills + p_kills, deaths = deaths + p_deaths, aces = aces + p_aces where lower(username) = lower(p_username);
$$;

create or replace function admin.set_pr (p_username text, p_pr numeric) returns void language sql as $$
  update public.players set pr = p_pr where lower(username) = lower(p_username);
$$;

create or replace function admin.set_tokens (p_username text, p_tokens int) returns void language sql as $$
  update public.players set tokens = greatest(0, p_tokens) where lower(username) = lower(p_username);
$$;

create or replace function admin.give_tokens (p_username text, p_tokens int) returns void language sql as $$
  update public.players set tokens = greatest(0, tokens + p_tokens) where lower(username) = lower(p_username);
$$;

create or replace function admin.set_password (p_username text, p_new_password text) returns void language sql as $$
  update public.players set pass_hash = extensions.crypt(p_new_password, extensions.gen_salt('bf')) where lower(username) = lower(p_username);
  delete from public.sessions where player_id in (select id from public.players where lower(username) = lower(p_username));
$$;

create or replace function admin.rename_player (p_old text, p_new text) returns void language plpgsql as $$
begin
  if p_new !~ '^[A-Za-z0-9_]{3,16}$' then raise exception 'Bad gamertag format'; end if;
  update public.players set username = p_new where lower(username) = lower(p_old);
  if not found then raise exception 'Player % not found', p_old; end if;
end $$;

create or replace function admin.ban_player (p_username text, p_banned boolean) returns void language sql as $$
  update public.players set banned = p_banned where lower(username) = lower(p_username);
  delete from public.sessions where p_banned and player_id in (select id from public.players where lower(username) = lower(p_username));
$$;

create or replace function admin.delete_player (p_username text) returns void language sql as $$
  delete from public.players where lower(username) = lower(p_username);
$$;

create or replace function admin.give_badge (p_username text, p_badge text) returns void language plpgsql as $$
declare pid uuid;
begin
  if p_badge not in ('host','dev','youtuber','twitch') then raise exception 'Badge must be host, dev, youtuber or twitch'; end if;
  select id into pid from public.players where lower(username) = lower(p_username);
  if pid is null then raise exception 'Player % not found', p_username; end if;
  update public.players set badges = array_append(array_remove(coalesce(badges,'{}'), p_badge), p_badge) where id = pid;
end $$;

create or replace function admin.remove_badge (p_username text, p_badge text) returns void language plpgsql as $$
begin
  update public.players set badges = array_remove(coalesce(badges,'{}'), p_badge) where lower(username) = lower(p_username);
end $$;

create or replace view admin.knife_owners as
select k.key, k.name, coalesce(string_agg(p.username, ', ' order by p.username), '(in the vault)') as owner, count(pi.id) as copies
from public.knives k left join public.player_items pi on pi.item = k.key left join public.players p on p.id = pi.player_id
group by k.key, k.name, k.sort order by k.sort;

create or replace function admin.give_knife (p_username text, p_key text, p_allow_duplicate boolean default false) returns void language plpgsql as $$
declare pid uuid; owners text;
begin
  select id into pid from public.players where lower(username) = lower(p_username);
  if pid is null then raise exception 'Player % not found', p_username; end if;
  if not exists (select 1 from public.knives where key = p_key) then raise exception 'No knife with key %. Run: select key, name from public.knives;', p_key; end if;
  if not p_allow_duplicate and not (select multi from public.knives where key = p_key) then
    select string_agg(p.username, ', ') into owners from public.player_items pi join public.players p on p.id = pi.player_id where pi.item = p_key;
    if owners is not null then raise exception '% is already owned by %. Use admin.transfer_knife(from, to, key) to move it, or give_knife(user, key, true) for an extra copy.', p_key, owners; end if;
  end if;
  insert into public.player_items (player_id, item, source) values (pid, p_key, 'transfer');
end $$;

create or replace function admin.transfer_knife (p_from text, p_to text, p_key text) returns void language plpgsql as $$
declare fid uuid; tid uuid; rid uuid;
begin
  select id into fid from public.players where lower(username) = lower(p_from);
  select id into tid from public.players where lower(username) = lower(p_to);
  if fid is null then raise exception 'Player % not found', p_from; end if;
  if tid is null then raise exception 'Player % not found', p_to; end if;
  select id into rid from public.player_items where player_id = fid and item = p_key limit 1;
  if rid is null then raise exception '% doesn''t own %', p_from, p_key; end if;
  update public.player_items set player_id = tid, source = 'transfer' where id = rid;
end $$;

create or replace function admin.take_knife (p_username text, p_key text) returns void language plpgsql as $$
declare rid uuid;
begin
  select pi.id into rid from public.player_items pi join public.players p on p.id = pi.player_id where lower(p.username) = lower(p_username) and pi.item = p_key limit 1;
  if rid is null then raise exception '% doesn''t own %', p_username, p_key; end if;
  delete from public.player_items where id = rid;
end $$;

revoke all on schema admin from public, anon, authenticated;
revoke all on all functions in schema admin from public, anon, authenticated;

-- (was: drop column "Developer", drop column "Host" — now "if exists" so a re-run can't fail here)
alter table public.players drop column if exists "Developer", drop column if exists "Host";