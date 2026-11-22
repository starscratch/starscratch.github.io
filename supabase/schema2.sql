-- 스타 스크래치 2단계: 서버 뽑기, 카드 목록, 친구, 선물, 신고
-- SQL Editor에 통째로 붙여 넣고 Run 하세요. (schema.sql을 먼저 실행했어야 해요)

-- ── 카드 목록 (서버가 아는 전체 카드) ──
create table public.card_catalog (
  card_key text primary key,
  tier text not null check (tier in ('common','rare','hero','legend','limited')),
  cond_weather text,           -- 눈/비/맑음/흐림 중 하나일 때만 나옴 (null이면 아무 때나)
  cond_time text,              -- morning/day/evening/night
  cond_region text,            -- 서울/부산/제주/대구/광주/강원
  active boolean not null default true
);

insert into public.card_catalog (card_key,tier,cond_weather,cond_time,cond_region) values
 ('솜솜','common',null,null,null),
 ('귤냥','common',null,null,null),
 ('뭉치','common','눈',null,null),
 ('도리','common',null,'night',null),
 ('붕이','common',null,null,null),
 ('코코','common',null,'morning',null),
 ('반짝','rare',null,null,null),
 ('호호','rare',null,'evening',null),
 ('딩동','rare',null,null,null),
 ('초록','rare',null,null,'제주'),
 ('따끔','hero',null,null,null),
 ('설탕별','hero','눈',null,null),
 ('오로라','hero',null,'night','강원'),
 ('겨울왕고래','legend',null,null,'부산'),
 ('첫눈 요정','legend','눈',null,null),
 ('성탄밤','limited',null,null,null);

alter table public.card_catalog enable row level security;
create policy "catalog read" on public.card_catalog for select using (true);

-- ── 친구 ──
create table public.friend_links (
  from_id uuid not null references public.profiles(id) on delete cascade,
  to_id   uuid not null references public.profiles(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending','accepted','blocked')),
  created_at timestamptz not null default now(),
  primary key (from_id, to_id),
  check (from_id <> to_id)
);
alter table public.friend_links enable row level security;
create policy "links involving me" on public.friend_links for select
  using (auth.uid() = from_id or auth.uid() = to_id);

-- ── 신고 ──
create table public.reports (
  id bigint generated always as identity primary key,
  reporter uuid not null references public.profiles(id) on delete cascade,
  target_friend_code text not null,
  reason text not null check (char_length(reason) <= 300),
  created_at timestamptz not null default now()
);
alter table public.reports enable row level security;
create policy "report insert" on public.reports for insert with check (auth.uid() = reporter);

-- ── 서버 뽑기 (휴대폰에서 조작 불가) ──
create or replace function public.draw_card(p_paid boolean, p_region text, p_weather text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  prof profiles%rowtype;
  v_tier text; v_key text; v_dup boolean; v_gain int := 0;
  r numeric; v_time text; h int;
begin
  if me is null then raise exception 'not signed in'; end if;
  select * into prof from profiles where id = me for update;
  if prof.last_draw_date is distinct from current_date then
    prof.draws_today := 0; prof.last_draw_date := current_date;
  end if;
  if p_paid then
    if prof.dust < 100 then return jsonb_build_object('error','no_dust'); end if;
    prof.dust := prof.dust - 100;
  else
    if prof.draws_today >= 3 then return jsonb_build_object('error','no_draws'); end if;
    prof.draws_today := prof.draws_today + 1;
  end if;

  r := random() * 100;
  if prof.pity <= 1 then
    r := random() * 12;
    v_tier := case when r < 9 then 'hero' when r < 11.5 then 'legend' else 'limited' end;
  else
    v_tier := case when r < 60 then 'common' when r < 88 then 'rare'
                   when r < 97 then 'hero' when r < 99.5 then 'legend' else 'limited' end;
  end if;
  prof.pity := case when v_tier in ('hero','legend','limited') then 31 else prof.pity - 1 end;

  h := extract(hour from now() at time zone 'Asia/Seoul');
  v_time := case when h between 5 and 10 then 'morning' when h between 11 and 16 then 'day'
                 when h between 17 and 20 then 'evening' else 'night' end;

  select card_key into v_key from card_catalog
   where tier = v_tier and active
     and (cond_weather is null or cond_weather = p_weather)
     and (cond_time    is null or cond_time    = v_time)
     and (cond_region  is null or cond_region  = p_region)
   order by random() limit 1;
  if v_key is null then
    select card_key into v_key from card_catalog where tier = v_tier and active
      and cond_weather is null and cond_time is null and cond_region is null
      order by random() limit 1;
  end if;

  v_dup := exists (select 1 from cards where owner = me and card_key = v_key);
  if v_dup then
    v_gain := case v_tier when 'common' then 5 when 'rare' then 20 when 'hero' then 60
                          when 'legend' then 150 else 200 end;
    prof.dust := prof.dust + v_gain;
  end if;

  insert into cards (owner, card_key, tier, region, weather) values (me, v_key, v_tier, p_region, p_weather);
  update profiles set dust=prof.dust, pity=prof.pity, draws_today=prof.draws_today,
    last_draw_date=prof.last_draw_date where id = me;

  return jsonb_build_object('card_key',v_key,'tier',v_tier,'dup',v_dup,'dust_gain',v_gain,
    'dust',prof.dust,'pity',prof.pity,'draws_left',greatest(0,3-prof.draws_today));
end $$;

-- ── 친구 요청 ──
create or replace function public.send_friend_request(p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); target uuid; cnt int;
begin
  if me is null then raise exception 'not signed in'; end if;
  select id into target from profiles where friend_code = upper(trim(p_code));
  if target is null then return jsonb_build_object('error','not_found'); end if;
  if target = me then return jsonb_build_object('error','self'); end if;
  if exists (select 1 from friend_links where status='blocked'
             and ((from_id=me and to_id=target) or (from_id=target and to_id=me)))
    then return jsonb_build_object('error','blocked'); end if;
  if exists (select 1 from friend_links where status='accepted'
             and ((from_id=me and to_id=target) or (from_id=target and to_id=me)))
    then return jsonb_build_object('error','already'); end if;
  select count(*) into cnt from friend_links where status='accepted' and (from_id=me or to_id=me);
  if cnt >= 50 then return jsonb_build_object('error','cap'); end if;
  insert into friend_links (from_id, to_id) values (me, target)
    on conflict (from_id, to_id) do nothing;
  return jsonb_build_object('ok',true);
end $$;

create or replace function public.respond_friend_request(p_from uuid, p_accept boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); cnt int;
begin
  if me is null then raise exception 'not signed in'; end if;
  if p_accept then
    select count(*) into cnt from friend_links where status='accepted' and (from_id=me or to_id=me);
    if cnt >= 50 then return jsonb_build_object('error','cap'); end if;
    update friend_links set status='accepted' where from_id=p_from and to_id=me and status='pending';
  else
    delete from friend_links where from_id=p_from and to_id=me and status='pending';
  end if;
  return jsonb_build_object('ok',true);
end $$;

create or replace function public.block_user(p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); target uuid;
begin
  if me is null then raise exception 'not signed in'; end if;
  select id into target from profiles where friend_code = upper(trim(p_code));
  if target is null then return jsonb_build_object('error','not_found'); end if;
  delete from friend_links where (from_id=me and to_id=target) or (from_id=target and to_id=me);
  insert into friend_links (from_id, to_id, status) values (me, target, 'blocked');
  return jsonb_build_object('ok',true);
end $$;

-- ── 내 친구/요청 목록 (닉네임은 친구 관계일 때만 보여 줌) ──
create or replace function public.my_relations()
returns jsonb language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'not signed in'; end if;
  return jsonb_build_object(
    'friends', coalesce((select jsonb_agg(jsonb_build_object('nick',p.nick,'code',p.friend_code))
      from friend_links f join profiles p on p.id = case when f.from_id=me then f.to_id else f.from_id end
      where f.status='accepted' and (f.from_id=me or f.to_id=me)), '[]'::jsonb),
    'pending_in', coalesce((select jsonb_agg(jsonb_build_object('nick',p.nick,'from_id',f.from_id))
      from friend_links f join profiles p on p.id = f.from_id
      where f.status='pending' and f.to_id=me), '[]'::jsonb),
    'pending_out', coalesce((select jsonb_agg(p.nick)
      from friend_links f join profiles p on p.id = f.to_id
      where f.status='pending' and f.from_id=me), '[]'::jsonb));
end $$;

-- ── 카드 선물 (하루 5번) ──
create or replace function public.gift_card(p_card_id bigint, p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); target uuid;
begin
  if me is null then raise exception 'not signed in'; end if;
  select id into target from profiles where friend_code = upper(trim(p_code));
  if target is null then return jsonb_build_object('error','not_found'); end if;
  if not exists (select 1 from friend_links where status='accepted'
      and ((from_id=me and to_id=target) or (from_id=target and to_id=me)))
    then return jsonb_build_object('error','not_friend'); end if;
  update cards set owner = target where id = p_card_id and owner = me;
  if not found then return jsonb_build_object('error','not_yours'); end if;
  return jsonb_build_object('ok',true);
end $$;

revoke all on function public.draw_card(boolean,text,text) from anon;
revoke all on function public.send_friend_request(text) from anon;
revoke all on function public.respond_friend_request(uuid,boolean) from anon;
revoke all on function public.block_user(text) from anon;
revoke all on function public.my_relations() from anon;
revoke all on function public.gift_card(bigint,text) from anon;
