-- 스타 스크래치 전체 설정 (이 파일 하나만 실행하면 됩니다)
-- Supabase SQL Editor -> New query -> 전체 붙여 넣기 -> Run


create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  nick text not null check (char_length(nick) between 2 and 10),
  grade text not null,
  guardian_email text,
  guardian_consented boolean not null default false,
  recovery_code text unique not null,
  friend_code text unique not null,
  dust int not null default 0 check (dust >= 0),
  pity int not null default 31 check (pity between 1 and 31),
  draws_today int not null default 0,
  last_draw_date date,
  created_at timestamptz not null default now()
);

create table public.cards (
  id bigint generated always as identity primary key,
  owner uuid not null references public.profiles(id) on delete cascade,
  card_key text not null,
  tier text not null check (tier in ('common','rare','hero','legend','limited')),
  region text,
  weather text,
  drawn_at timestamptz not null default now()
);
create index cards_owner_idx on public.cards(owner);

alter table public.profiles enable row level security;
alter table public.cards enable row level security;

-- 내 것만 보고 만지기
create policy "own profile read"   on public.profiles for select using (auth.uid() = id);
create policy "own profile insert" on public.profiles for insert with check (auth.uid() = id);
create policy "own profile update" on public.profiles for update using (auth.uid() = id);

create policy "own cards read"   on public.cards for select using (auth.uid() = owner);
create policy "own cards insert" on public.cards for insert with check (auth.uid() = owner);


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


-- ── 출석 보상 ──
alter table public.profiles add column if not exists attendance_streak int not null default 0;
alter table public.profiles add column if not exists last_login_date date;

create or replace function public.daily_checkin()
returns jsonb language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); prof profiles%rowtype; gain int := 0; streak int;
begin
  if me is null then raise exception 'not signed in'; end if;
  select * into prof from profiles where id = me for update;
  if prof.last_login_date is not distinct from current_date then
    return jsonb_build_object('already',true,'streak',prof.attendance_streak,'dust',prof.dust);
  end if;
  streak := case when prof.last_login_date = current_date - 1 then prof.attendance_streak + 1 else 1 end;
  gain := 10;
  if streak % 7 = 0 then gain := gain + 100; end if;
  update profiles set attendance_streak = streak, last_login_date = current_date, dust = dust + gain
   where id = me;
  return jsonb_build_object('already',false,'gain',gain,'streak',streak,'dust',prof.dust+gain);
end $$;
revoke all on function public.daily_checkin() from anon;

-- ── 숨겨진 카드 (도감에 이름이 안 보임, 조건을 채우면 나옴) ──
alter table public.card_catalog add column if not exists hidden boolean not null default false;
insert into public.card_catalog (card_key,tier,cond_weather,cond_time,cond_region,hidden) values
 ('눈사람의 혼','rare','눈','night',null,true),
 ('아침의 유령','hero',null,'morning',null,true)
on conflict (card_key) do nothing;

-- ── 카드 합성 (비밀 조합식) ──
create table if not exists public.fusion_recipes (
  key_a text not null,
  key_b text not null,
  result text not null,
  primary key (key_a, key_b)
);
insert into public.fusion_recipes (key_a,key_b,result) values
 ('솜솜','뭉치','눈사람의 혼'),
 ('코코','반짝','아침의 유령'),
 ('귤냥','초록','호호')
on conflict do nothing;
alter table public.fusion_recipes enable row level security;
-- 조합식은 비밀이라 아무도 직접 못 읽음 (RPC로만 시도)

create or replace function public.fuse_cards(p_key_a text, p_key_b text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); v_result text; v_tier text; id_a bigint; id_b bigint;
begin
  if me is null then raise exception 'not signed in'; end if;
  select result into v_result from fusion_recipes
   where (key_a=p_key_a and key_b=p_key_b) or (key_a=p_key_b and key_b=p_key_a);
  if v_result is null then return jsonb_build_object('error','no_recipe'); end if;
  select id into id_a from cards where owner=me and card_key=p_key_a limit 1;
  select id into id_b from cards where owner=me and card_key=p_key_b and id is distinct from id_a limit 1;
  if id_a is null or id_b is null then return jsonb_build_object('error','missing'); end if;
  delete from cards where id in (id_a,id_b);
  select tier into v_tier from card_catalog where card_key=v_result;
  insert into cards (owner,card_key,tier) values (me,v_result,coalesce(v_tier,'rare'));
  return jsonb_build_object('ok',true,'result',v_result,'tier',coalesce(v_tier,'rare'));
end $$;
revoke all on function public.fuse_cards(text,text) from anon;

-- ── 크리스마스 한정 카드 (12월 동안만) ──
insert into public.card_catalog (card_key,tier,cond_weather,cond_time,cond_region,hidden) values
 ('루돌프 뭉치','rare',null,null,null,false),
 ('산타 귤냥','hero',null,null,null,false),
 ('크리스마스 트리별','legend',null,'night',null,false)
on conflict (card_key) do nothing;
