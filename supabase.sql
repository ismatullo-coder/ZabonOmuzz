-- ZabonOmuz — paste this whole file in Supabase: SQL Editor → New query → Run
-- Matches the live site: profiles, battles, xp_log, likes, follows, comments, inbox, rating.

create extension if not exists pgcrypto;

-- ---------- tables (create if missing, then add any missing columns) ----------
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  name text default '',
  surname text default '',
  registered_at timestamptz default now(),
  learn_lang text,
  declared_level text,
  referral text,
  progress jsonb default '{}'::jsonb,
  stats jsonb default '{}'::jsonb,
  avatar_hue integer default 260,
  avatar_photo text,
  ui_lang text default 'tj',
  dark boolean default true
);

alter table public.profiles add column if not exists email text;
alter table public.profiles add column if not exists name text default '';
alter table public.profiles add column if not exists surname text default '';
alter table public.profiles add column if not exists registered_at timestamptz default now();
alter table public.profiles add column if not exists learn_lang text;
alter table public.profiles add column if not exists declared_level text;
alter table public.profiles add column if not exists referral text;
alter table public.profiles add column if not exists progress jsonb default '{}'::jsonb;
alter table public.profiles add column if not exists stats jsonb default '{}'::jsonb;
alter table public.profiles add column if not exists avatar_hue integer default 260;
alter table public.profiles add column if not exists avatar_photo text;
alter table public.profiles add column if not exists ui_lang text default 'tj';
alter table public.profiles add column if not exists dark boolean default true;

do $$
begin
  create unique index if not exists profiles_email_lower_idx on public.profiles (lower(email));
exception when others then
  null;
end $$;

create table if not exists public.battles (
  id uuid primary key default gen_random_uuid(),
  challenger_email text not null,
  challenger_name text,
  opponent_email text not null,
  opponent_name text,
  seed bigint,
  status text not null default 'invited',
  challenger_score integer,
  opponent_score integer,
  created_at timestamptz default now()
);

alter table public.battles add column if not exists challenger_email text;
alter table public.battles add column if not exists challenger_name text;
alter table public.battles add column if not exists opponent_email text;
alter table public.battles add column if not exists opponent_name text;
alter table public.battles add column if not exists seed bigint;
alter table public.battles add column if not exists status text;
alter table public.battles add column if not exists challenger_score integer;
alter table public.battles add column if not exists opponent_score integer;
alter table public.battles add column if not exists created_at timestamptz default now();

create index if not exists battles_opponent_status_idx on public.battles (lower(opponent_email), status);
create index if not exists battles_challenger_status_idx on public.battles (lower(challenger_email), status);

create table if not exists public.xp_log (
  id bigint generated always as identity primary key,
  email text not null,
  ts bigint not null,
  xp integer not null default 0
);

alter table public.xp_log add column if not exists email text;
alter table public.xp_log add column if not exists ts bigint;
alter table public.xp_log add column if not exists xp integer default 0;

create index if not exists xp_log_email_ts_idx on public.xp_log (lower(email), ts);

-- ---------- helper: current user's email ----------
create or replace function public.my_email()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select lower(trim(coalesce(
    (select p.email from public.profiles p where p.id = auth.uid() limit 1),
    auth.jwt()->>'email',
    ''
  )));
$$;

-- ---------- social: like / follow / comment / inbox (bypass RLS safely) ----------
create or replace function public.toggle_like(target_email text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  me text := public.my_email();
  target text := lower(trim(coalesce(target_email, '')));
  st jsonb;
  arr jsonb;
  has_me boolean;
begin
  if me is null or me = '' then raise exception 'login required'; end if;
  if target = '' then raise exception 'no target'; end if;

  select coalesce(stats, '{}'::jsonb) into st
  from public.profiles where lower(email) = target;
  if not found then raise exception 'profile not found'; end if;

  arr := coalesce(st->'likedBy', '[]'::jsonb);
  if jsonb_typeof(arr) <> 'array' then arr := '[]'::jsonb; end if;

  select exists(
    select 1 from jsonb_array_elements_text(arr) v where lower(v) = me
  ) into has_me;

  if has_me then
    select coalesce(jsonb_agg(to_jsonb(v)), '[]'::jsonb) into arr
    from jsonb_array_elements_text(arr) v
    where lower(v) <> me;
  else
    arr := arr || jsonb_build_array(me);
  end if;

  st := jsonb_set(st, '{likedBy}', coalesce(arr, '[]'::jsonb), true);
  update public.profiles set stats = st where lower(email) = target;
  return st;
end;
$$;

create or replace function public.toggle_follow(target_email text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  me text := public.my_email();
  target text := lower(trim(coalesce(target_email, '')));
  their jsonb;
  mine jsonb;
  arr jsonb;
  has_me boolean;
begin
  if me is null or me = '' then raise exception 'login required'; end if;
  if target = '' or target = me then raise exception 'bad target'; end if;

  select coalesce(stats, '{}'::jsonb) into their
  from public.profiles where lower(email) = target;
  if not found then raise exception 'profile not found'; end if;

  select coalesce(stats, '{}'::jsonb) into mine
  from public.profiles where lower(email) = me;
  if not found then raise exception 'profile not found'; end if;

  arr := coalesce(their->'followers', '[]'::jsonb);
  if jsonb_typeof(arr) <> 'array' then arr := '[]'::jsonb; end if;
  select exists(select 1 from jsonb_array_elements_text(arr) v where lower(v) = me) into has_me;
  if has_me then
    select coalesce(jsonb_agg(to_jsonb(v)), '[]'::jsonb) into arr
    from jsonb_array_elements_text(arr) v where lower(v) <> me;
  else
    arr := arr || jsonb_build_array(me);
  end if;
  their := jsonb_set(their, '{followers}', coalesce(arr, '[]'::jsonb), true);

  arr := coalesce(mine->'following', '[]'::jsonb);
  if jsonb_typeof(arr) <> 'array' then arr := '[]'::jsonb; end if;
  if has_me then
    select coalesce(jsonb_agg(to_jsonb(v)), '[]'::jsonb) into arr
    from jsonb_array_elements_text(arr) v where lower(v) <> target;
  else
    arr := arr || jsonb_build_array(target);
  end if;
  mine := jsonb_set(mine, '{following}', coalesce(arr, '[]'::jsonb), true);

  update public.profiles set stats = their where lower(email) = target;
  update public.profiles set stats = mine where lower(email) = me;
  return jsonb_build_object('their', their, 'mine', mine);
end;
$$;

create or replace function public.add_profile_comment(target_email text, comment_text text, from_name text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  me text := public.my_email();
  target text := lower(trim(coalesce(target_email, '')));
  body text := left(trim(coalesce(comment_text, '')), 400);
  st jsonb;
  arr jsonb;
begin
  if me is null or me = '' then raise exception 'login required'; end if;
  if target = '' then raise exception 'no target'; end if;
  if body = '' then raise exception 'empty comment'; end if;

  select coalesce(stats, '{}'::jsonb) into st
  from public.profiles where lower(email) = target;
  if not found then raise exception 'profile not found'; end if;

  arr := coalesce(st->'comments', '[]'::jsonb);
  if jsonb_typeof(arr) <> 'array' then arr := '[]'::jsonb; end if;
  arr := arr || jsonb_build_array(jsonb_build_object(
    'from', me,
    'name', left(coalesce(from_name, ''), 80),
    'text', body,
    'ts', (extract(epoch from now()) * 1000)::bigint
  ));
  while jsonb_array_length(arr) > 80 loop
    arr := arr - 0;
  end loop;

  st := jsonb_set(st, '{comments}', arr, true);
  update public.profiles set stats = st where lower(email) = target;
  return st;
end;
$$;

create or replace function public.push_profile_inbox(target_email text, item jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  me text := public.my_email();
  target text := lower(trim(coalesce(target_email, '')));
  st jsonb;
  arr jsonb;
begin
  if me is null or me = '' then raise exception 'login required'; end if;
  if target = '' then raise exception 'no target'; end if;

  select coalesce(stats, '{}'::jsonb) into st
  from public.profiles where lower(email) = target;
  if not found then raise exception 'profile not found'; end if;

  arr := coalesce(st->'inbox', '[]'::jsonb);
  if jsonb_typeof(arr) <> 'array' then arr := '[]'::jsonb; end if;
  arr := jsonb_build_array(coalesce(item, '{}'::jsonb)) || arr;
  while jsonb_array_length(arr) > 40 loop
    arr := arr - (jsonb_array_length(arr) - 1);
  end loop;

  st := jsonb_set(st, '{inbox}', arr, true);
  update public.profiles set stats = st where lower(email) = target;
  return st;
end;
$$;

-- ---------- wipe old RLS policies so they cannot block likes / rating ----------
do $$
declare pol record;
begin
  for pol in
    select schemaname, tablename, policyname
    from pg_policies
    where schemaname = 'public'
      and tablename in ('profiles', 'battles', 'xp_log')
  loop
    execute format('drop policy if exists %I on %I.%I', pol.policyname, pol.schemaname, pol.tablename);
  end loop;
end $$;

alter table public.profiles enable row level security;
alter table public.battles enable row level security;
alter table public.xp_log enable row level security;

-- Rating + shared profile links: anyone can READ profiles (no passwords here).
create policy profiles_select_all on public.profiles
  for select to anon, authenticated
  using (true);

create policy profiles_insert_own on public.profiles
  for insert to authenticated
  with check (id = auth.uid());

-- Own row only: XP, progress, photo. Likes/follows go through the functions above.
create policy profiles_update_own on public.profiles
  for update to authenticated
  using (id = auth.uid())
  with check (id = auth.uid());

create policy battles_select_mine on public.battles
  for select to authenticated
  using (
    lower(challenger_email) = public.my_email()
    or lower(opponent_email) = public.my_email()
  );

create policy battles_insert_mine on public.battles
  for insert to authenticated
  with check (lower(challenger_email) = public.my_email());

create policy battles_update_mine on public.battles
  for update to authenticated
  using (
    lower(challenger_email) = public.my_email()
    or lower(opponent_email) = public.my_email()
  )
  with check (
    lower(challenger_email) = public.my_email()
    or lower(opponent_email) = public.my_email()
  );

create policy xp_log_select_all on public.xp_log
  for select to anon, authenticated
  using (true);

create policy xp_log_insert_own on public.xp_log
  for insert to authenticated
  with check (lower(email) = public.my_email());

-- ---------- grants ----------
grant usage on schema public to anon, authenticated;

grant select on public.profiles to anon, authenticated;
grant insert, update on public.profiles to authenticated;

grant select, insert, update on public.battles to authenticated;

grant select on public.xp_log to anon, authenticated;
grant insert on public.xp_log to authenticated;

grant execute on function public.my_email() to anon, authenticated;
grant execute on function public.toggle_like(text) to authenticated;
grant execute on function public.toggle_follow(text) to authenticated;
grant execute on function public.add_profile_comment(text, text, text) to authenticated;
grant execute on function public.push_profile_inbox(text, jsonb) to authenticated;

notify pgrst, 'reload schema';
