-- =====================================================================
-- MOTHERLODE — UPDATE: event editor, player insights, ad limit fix
-- Paste this whole file into the Supabase SQL editor and run it once.
-- Safe to re-run. It only adds/replaces functions; no data is removed.
-- =====================================================================

-- ---------- 1. ONE AD PER DAY, ENFORCED ON THE SERVER ----------
-- Before: the "already watched today" check only lived in the browser, so logging in on
-- another browser (or clearing site data) let you watch and claim again.
-- Now the database refuses a second claimed ad in the same day (resets at midnight Central,
-- same as the daily chest), no matter which browser or device you use.

create or replace function public.ad_claimed_today (p_player uuid) returns boolean language sql stable security definer set search_path = public, extensions as $$
  select exists (select 1 from public.ad_views
                 where player_id = p_player and claimed_at is not null
                   and (claimed_at at time zone 'America/Chicago')::date = public.chest_today());
$$;

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

-- game_state now also tells the page whether today's ad is still available (ad_ready / next_ad).
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


-- ---------- 2. ADMIN: CREATE / EDIT / DELETE EVENTS ----------
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


-- ---------- 3. PLAYER INSIGHTS (Stats page) ----------
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


-- ---------- 4. PANEL GATEWAY: event calls belong to the Host panel ----------
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


-- ---------- 5. PERMISSIONS ----------
-- internal helpers + admin calls: not callable from the website directly (only through panel_call)
revoke all on function public.ad_claimed_today (uuid) from public, anon, authenticated;
revoke all on function public.admin_events (text) from public, anon, authenticated;
revoke all on function public.admin_save_event (text, text, text, text, timestamptz, timestamptz, text, text, text, jsonb, jsonb) from public, anon, authenticated;
revoke all on function public.admin_delete_event (text, text) from public, anon, authenticated;

-- player-facing calls
revoke all on function public.player_insights (text, text), public.game_state (text), public.start_ad (text), public.claim_ad (text, uuid), public.panel_call (text, text, text, jsonb) from public;
grant execute on function public.player_insights (text, text), public.game_state (text), public.start_ad (text), public.claim_ad (text, uuid), public.panel_call (text, text, text, jsonb) to anon, authenticated;
