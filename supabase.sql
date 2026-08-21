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

-- ---------- likes / follows / comments / inbox (real tables for the site) ----------
create table if not exists public.profile_likes (
  liker_email text not null,
  profile_email text not null,
  created_at timestamptz default now(),
  primary key (liker_email, profile_email)
);
create index if not exists profile_likes_profile_idx on public.profile_likes (lower(profile_email));

create table if not exists public.profile_follows (
  follower_email text not null,
  profile_email text not null,
  created_at timestamptz default now(),
  primary key (follower_email, profile_email)
);
create index if not exists profile_follows_profile_idx on public.profile_follows (lower(profile_email));
create index if not exists profile_follows_follower_idx on public.profile_follows (lower(follower_email));

create table if not exists public.profile_comments (
  id uuid primary key default gen_random_uuid(),
  profile_email text not null,
  from_email text not null,
  from_name text default '',
  body text not null,
  ts bigint not null default ((extract(epoch from now()) * 1000)::bigint)
);
create index if not exists profile_comments_profile_idx on public.profile_comments (lower(profile_email), ts);

create table if not exists public.profile_inbox (
  id uuid primary key default gen_random_uuid(),
  email text not null,
  from_email text not null,
  item jsonb not null default '{}'::jsonb,
  ts bigint not null default ((extract(epoch from now()) * 1000)::bigint)
);
create index if not exists profile_inbox_email_idx on public.profile_inbox (lower(email), ts desc);

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

-- ---------- social RPCs (write to the tables above) ----------
create or replace function public.toggle_like(target_email text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  me text := public.my_email();
  target text := lower(trim(coalesce(target_email, '')));
  has_me boolean;
  arr jsonb;
begin
  if me is null or me = '' then raise exception 'login required'; end if;
  if target = '' then raise exception 'no target'; end if;

  select exists(
    select 1 from public.profile_likes
    where lower(liker_email)=me and lower(profile_email)=target
  ) into has_me;

  if has_me then
    delete from public.profile_likes
    where lower(liker_email)=me and lower(profile_email)=target;
  else
    insert into public.profile_likes(liker_email, profile_email)
    values (me, target)
    on conflict (liker_email, profile_email) do nothing;
  end if;

  select coalesce(jsonb_agg(liker_email), '[]'::jsonb) into arr
  from public.profile_likes where lower(profile_email)=target;
  return jsonb_build_object('likedBy', arr);
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
  has_me boolean;
  theirs jsonb;
  mine jsonb;
begin
  if me is null or me = '' then raise exception 'login required'; end if;
  if target = '' or target = me then raise exception 'bad target'; end if;

  select exists(
    select 1 from public.profile_follows
    where lower(follower_email)=me and lower(profile_email)=target
  ) into has_me;

  if has_me then
    delete from public.profile_follows
    where lower(follower_email)=me and lower(profile_email)=target;
  else
    insert into public.profile_follows(follower_email, profile_email)
    values (me, target)
    on conflict (follower_email, profile_email) do nothing;
  end if;

  select coalesce(jsonb_agg(follower_email), '[]'::jsonb) into theirs
  from public.profile_follows where lower(profile_email)=target;
  select coalesce(jsonb_agg(profile_email), '[]'::jsonb) into mine
  from public.profile_follows where lower(follower_email)=me;

  return jsonb_build_object(
    'their', jsonb_build_object('followers', theirs),
    'mine', jsonb_build_object('following', mine)
  );
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
  arr jsonb;
begin
  if me is null or me = '' then raise exception 'login required'; end if;
  if target = '' then raise exception 'no target'; end if;
  if body = '' then raise exception 'empty comment'; end if;

  insert into public.profile_comments(profile_email, from_email, from_name, body, ts)
  values (target, me, left(coalesce(from_name,''), 80), body, (extract(epoch from now())*1000)::bigint);

  delete from public.profile_comments
  where id in (
    select id from public.profile_comments
    where lower(profile_email)=target
    order by ts desc
    offset 80
  );

  select coalesce(jsonb_agg(jsonb_build_object(
    'from', c.from_email, 'name', c.from_name, 'text', c.body, 'ts', c.ts
  ) order by c.ts), '[]'::jsonb) into arr
  from public.profile_comments c where lower(c.profile_email)=target;
  return jsonb_build_object('comments', arr);
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
begin
  if me is null or me = '' then raise exception 'login required'; end if;
  if target = '' then raise exception 'no target'; end if;

  insert into public.profile_inbox(email, from_email, item, ts)
  values (target, me, coalesce(item, '{}'::jsonb), (extract(epoch from now())*1000)::bigint);

  delete from public.profile_inbox
  where id in (
    select id from public.profile_inbox
    where lower(email)=target
    order by ts desc
    offset 40
  );
  return item;
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
      and tablename in ('profiles', 'battles', 'xp_log', 'profile_likes', 'profile_follows', 'profile_comments', 'profile_inbox')
  loop
    execute format('drop policy if exists %I on %I.%I', pol.policyname, pol.schemaname, pol.tablename);
  end loop;
end $$;

alter table public.profiles enable row level security;
alter table public.battles enable row level security;
alter table public.xp_log enable row level security;
alter table public.profile_likes enable row level security;
alter table public.profile_follows enable row level security;
alter table public.profile_comments enable row level security;
alter table public.profile_inbox enable row level security;

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

create policy profile_likes_select on public.profile_likes
  for select to anon, authenticated using (true);
create policy profile_likes_insert on public.profile_likes
  for insert to authenticated
  with check (lower(liker_email) = public.my_email());
create policy profile_likes_delete on public.profile_likes
  for delete to authenticated
  using (lower(liker_email) = public.my_email());

create policy profile_follows_select on public.profile_follows
  for select to anon, authenticated using (true);
create policy profile_follows_insert on public.profile_follows
  for insert to authenticated
  with check (lower(follower_email) = public.my_email() and lower(profile_email) <> public.my_email());
create policy profile_follows_delete on public.profile_follows
  for delete to authenticated
  using (lower(follower_email) = public.my_email());

create policy profile_comments_select on public.profile_comments
  for select to anon, authenticated using (true);
create policy profile_comments_insert on public.profile_comments
  for insert to authenticated
  with check (lower(from_email) = public.my_email());
create policy profile_comments_delete on public.profile_comments
  for delete to authenticated
  using (lower(from_email) = public.my_email());

create policy profile_inbox_select on public.profile_inbox
  for select to authenticated
  using (lower(email) = public.my_email());
create policy profile_inbox_insert on public.profile_inbox
  for insert to authenticated
  with check (lower(from_email) = public.my_email());

-- ---------- grants ----------
grant usage on schema public to anon, authenticated;

grant select on public.profiles to anon, authenticated;
grant insert, update on public.profiles to authenticated;

grant select, insert, update on public.battles to authenticated;

grant select on public.xp_log to anon, authenticated;
grant insert on public.xp_log to authenticated;

grant select on public.profile_likes to anon, authenticated;
grant insert, delete on public.profile_likes to authenticated;
grant select on public.profile_follows to anon, authenticated;
grant insert, delete on public.profile_follows to authenticated;
grant select on public.profile_comments to anon, authenticated;
grant insert, delete on public.profile_comments to authenticated;
grant select, insert on public.profile_inbox to authenticated;

grant execute on function public.my_email() to anon, authenticated;
grant execute on function public.toggle_like(text) to authenticated;
grant execute on function public.toggle_follow(text) to authenticated;
grant execute on function public.add_profile_comment(text, text, text) to authenticated;
grant execute on function public.push_profile_inbox(text, jsonb) to authenticated;

notify pgrst, 'reload schema';
