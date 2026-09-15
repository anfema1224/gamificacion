-- Maestro de la Planta: dificultad creciente, tablero depurado y respuesta docente.

create or replace function private.torneo_start_phase_impl(p_code text, p_host_token text)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  t public.tournaments%rowtype;
  ph public.phases%rowtype;
  v_next integer;
  v_count integer;
  v_levels integer;
  v_base integer;
  v_rem integer;
begin
  t := private.require_host(p_code, p_host_token);
  if t.status = 'finished' then raise exception 'El torneo ya terminó'; end if;
  if t.status not in ('lobby', 'phase_complete') then raise exception 'La fase actual todavía está en curso'; end if;

  v_next := case when t.status = 'lobby' then 1 else t.current_phase_no + 1 end;
  if v_next > 5 then raise exception 'No hay otra fase'; end if;

  if v_next = 1 then
    select count(*) into v_count
    from public.participants
    where tournament_id = t.id and status = 'active';
    if v_count < 2 then raise exception 'Se necesitan al menos 2 participantes'; end if;
  end if;

  select * into ph
  from public.phases
  where tournament_id = t.id and phase_no = v_next;

  select count(*) into v_count
  from public.phase_questions
  where phase_id = ph.id;

  if v_count = 0 then
    v_levels := ph.level_max - ph.level_min + 1;
    v_base := ph.question_count / v_levels;
    v_rem := ph.question_count % v_levels;

    insert into public.phase_questions(tournament_id, phase_id, position, question_id)
    with level_order as (
      select gs as level, row_number() over(order by random()) as extra_rank
      from generate_series(ph.level_min, ph.level_max) gs
    ), quotas as (
      select level, v_base + case when extra_rank <= v_rem then 1 else 0 end as quota
      from level_order
    ), candidates as (
      select q.id, q.level, row_number() over(partition by q.level order by random()) as rn
      from public.questions q
      where q.active = true
        and q.level between ph.level_min and ph.level_max
        and q.difficulty_band = v_next
        and q.id not in (
          select pq.question_id
          from public.phase_questions pq
          where pq.tournament_id = t.id
        )
    ), picked as (
      select c.id, c.level
      from candidates c
      join quotas qt on qt.level = c.level
      where c.rn <= qt.quota
    ), ordered as (
      select id, row_number() over(order by level asc, random())::integer as position
      from picked
    )
    select t.id, ph.id, o.position, o.id
    from ordered o;

    select count(*) into v_count
    from public.phase_questions
    where phase_id = ph.id;
    if v_count < ph.question_count then
      raise exception 'No hay suficientes preguntas configuradas para esta fase y dificultad';
    end if;
  end if;

  update public.participants
  set phase_score = 0, phase_correct = 0, phase_response_ms = 0, current_phase = v_next
  where tournament_id = t.id and status = 'active';

  update public.phases
  set status = 'active', started_at = coalesce(started_at, now()), finished_at = null
  where id = ph.id;

  update public.tournaments
  set status = 'phase_active', current_phase_no = v_next, current_question_pos = 0,
      question_started_at = null, question_deadline = null
  where id = t.id;

  return jsonb_build_object(
    'ok', true,
    'phaseNo', v_next,
    'difficultyBand', v_next,
    'difficultyLabel', case v_next
      when 1 then 'Básica'
      when 2 then 'Intermedia'
      when 3 then 'Intermedia alta'
      when 4 then 'Avanzada'
      when 5 then 'Experta'
    end
  );
end;
$function$;

create or replace function private.torneo_state_impl(p_code text, p_token text)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  t public.tournaments%rowtype;
  ph public.phases%rowtype;
  me public.participants%rowtype;
  v_role text;
  v_q jsonb := null;
  v_qid text;
  v_answered boolean := false;
  v_answer_count integer := 0;
  v_players jsonb := '[]'::jsonb;
  v_teams jsonb := '[]'::jsonb;
  v_player_count integer := 0;
  v_active_count integer := 0;
  v_my_rank integer := null;
  v_can_answer boolean := false;
  v_reveal_correct boolean := false;
begin
  select * into t from public.tournaments where code = private.norm_code(p_code);
  if not found then raise exception 'Sala no encontrada'; end if;

  if private.is_host_token(t.id, p_token) then
    v_role := 'host';
  else
    select * into me from public.participants
    where tournament_id = t.id and session_token_hash = private.token_hash(p_token);
    if not found then raise exception 'Token de participante no válido'; end if;
    v_role := 'player';
  end if;

  if t.current_phase_no > 0 then
    select * into ph from public.phases where tournament_id = t.id and phase_no = t.current_phase_no;
  end if;

  select count(*), count(*) filter(where status in ('active', 'champion'))
  into v_player_count, v_active_count
  from public.participants
  where tournament_id = t.id;

  select coalesce(jsonb_agg(x.obj order by x.phase_score desc, x.phase_correct desc, x.phase_response_ms asc, x.joined_at asc), '[]'::jsonb)
  into v_players
  from (
    select phase_score, phase_correct, phase_response_ms, joined_at,
      jsonb_build_object(
        'id', id, 'nickname', nickname, 'team_name', team_name, 'status', status,
        'current_phase', current_phase, 'phase_score', phase_score, 'total_score', total_score,
        'phase_correct', phase_correct, 'phase_response_ms', phase_response_ms,
        'total_response_ms', total_response_ms, 'joined_at', joined_at
      ) obj
    from public.participants
    where tournament_id = t.id
      and (
        t.status not in ('phase_active', 'question_active')
        or t.current_phase_no <= 1
        or status <> 'eliminated'
      )
  ) x;

  if v_role = 'player' then
    select z.rn into v_my_rank
    from (
      select id, row_number() over(order by phase_score desc, phase_correct desc, phase_response_ms asc, joined_at asc) rn
      from public.participants
      where tournament_id = t.id
    ) z
    where z.id = me.id;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('name', z.team_name, 'score', z.score, 'active', z.active) order by z.score desc), '[]'::jsonb)
  into v_teams
  from (
    select team_name, sum(total_score)::bigint score,
      count(*) filter(where status in ('active', 'champion'))::integer active
    from public.participants
    where tournament_id = t.id and team_name is not null
    group by team_name
  ) z;

  if ph.id is not null and t.current_question_pos > 0 then
    select pq.question_id into v_qid
    from public.phase_questions pq
    where pq.phase_id = ph.id and pq.position = t.current_question_pos;

    if v_qid is not null then
      v_reveal_correct := v_role = 'host'
        and t.status = 'question_active'
        and t.question_deadline is not null
        and now() >= t.question_deadline;

      select jsonb_build_object(
        'id', q.id, 'level', q.level, 'category', q.category, 'q', q.q, 'options', q.options,
        'correctIndex', case when v_reveal_correct then q.correct_index else null end
      ) into v_q
      from public.questions q
      where q.id = v_qid;

      if v_role = 'player' then
        select exists(
          select 1 from public.answers a
          where a.phase_id = ph.id and a.participant_id = me.id and a.question_id = v_qid
        ) into v_answered;
      end if;

      select count(*) into v_answer_count
      from public.answers a
      where a.phase_id = ph.id and a.question_id = v_qid;
    end if;
  end if;

  if v_role = 'player' then
    v_can_answer := v_qid is not null and me.status = 'active' and not v_answered
      and t.status = 'question_active' and t.question_deadline is not null and now() < t.question_deadline;
  end if;

  return jsonb_build_object(
    'role', v_role, 'tournament', (to_jsonb(t) - 'host_token_hash' - 'host_pin_hash'),
    'phase', case when ph.id is null then null else to_jsonb(ph) end,
    'me', case when v_role = 'player' then (to_jsonb(me) - 'session_token_hash') else null end,
    'leaderboard', v_players, 'playerCount', v_player_count, 'activeCount', v_active_count,
    'myRank', v_my_rank, 'question', v_q, 'hasAnswered', v_answered,
    'answerCount', v_answer_count, 'teamLeaderboard', v_teams, 'canAnswer', v_can_answer
  );
end;
$function$;
