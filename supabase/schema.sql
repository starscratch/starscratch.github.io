-- 스타 스크래치 데이터베이스 (v1)
-- Supabase SQL Editor에 통째로 붙여 넣고 Run 하세요.

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
