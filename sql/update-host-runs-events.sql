-- =====================================================================
-- MOTHERLODE — UPDATE: hosts run events
-- Only needed if you ALREADY ran update-events-stats-ads.sql before.
-- (If you haven't run that one yet, just run it instead; it already includes this.)
-- Moves event create / edit / delete / lock-unlock from the Admin panel (DEV badge)
-- to the Host panel (HOST badge). Safe to re-run.
-- =====================================================================

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

revoke all on function public.panel_call (text, text, text, jsonb) from public;
grant execute on function public.panel_call (text, text, text, jsonb) to anon, authenticated;
