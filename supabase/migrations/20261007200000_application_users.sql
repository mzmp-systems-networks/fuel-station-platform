-- Application users (Sprint 1, IAM).
-- Spec: docs/sprint-1/application-user-model.md (sections 5, 6, 7, 9).

-- ---------------------------------------------------------------------------
-- Baseline
-- ---------------------------------------------------------------------------

-- The hosted database already has public.users (created before migrations were
-- tracked). Recreate that definition on fresh databases (local, branches) so the
-- alterations below apply the same way everywhere. No-op on the hosted database.
create table if not exists public.users (
  id uuid not null default gen_random_uuid (),
  email character varying null,
  password character varying null,
  first_name character varying null,
  last_name character varying null,
  status character varying null,
  email_verified boolean null,
  created_at timestamp with time zone null,
  updated_at timestamp with time zone null,
  created_by uuid null,
  updated_by uuid null,
  constraint users_pkey primary key (id)
);

-- The only existing row is test data with no login and no business records (Q3).
delete from public.users;

-- ---------------------------------------------------------------------------
-- Table: target schema (section 9)
-- ---------------------------------------------------------------------------

create extension if not exists citext with schema extensions;

-- Credentials and verification belong to Supabase Auth (D4).
alter table public.users
  drop column if exists password,
  drop column if exists email_verified;

alter table public.users
  add column auth_user_id uuid,
  add column role text not null,
  alter column email      type extensions.citext using email::extensions.citext,
  alter column email      set not null,
  alter column first_name type text,
  alter column first_name set not null,
  alter column last_name  type text,
  alter column last_name  set not null,
  alter column status     type text,
  alter column status     set default 'INVITED',
  alter column status     set not null,
  alter column created_at set default now(),
  alter column created_at set not null,
  alter column updated_at set default now(),
  alter column updated_at set not null;

alter table public.users
  add constraint users_auth_user_id_key unique (auth_user_id),
  add constraint users_auth_user_id_fkey foreign key (auth_user_id) references auth.users (id) on delete set null,
  add constraint users_email_key unique (email),
  add constraint users_created_by_fkey foreign key (created_by) references public.users (id) on delete restrict,
  add constraint users_updated_by_fkey foreign key (updated_by) references public.users (id) on delete restrict,
  add constraint users_first_name_not_blank check (length(btrim(first_name)) > 0),
  add constraint users_last_name_not_blank  check (length(btrim(last_name)) > 0),
  add constraint users_email_format         check (email::text ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  add constraint users_status_valid         check (status in ('INVITED', 'ACTIVE', 'SUSPENDED', 'DEACTIVATED')),
  add constraint users_role_valid           check (role in ('ADMINISTRATOR', 'MANAGER', 'ATTENDANT')),
  -- A user who can (or is expected to again) sign in must have a linked login.
  add constraint users_login_required       check (status not in ('ACTIVE', 'SUSPENDED') or auth_user_id is not null),
  add constraint users_updated_after_created check (updated_at >= created_at);

create index users_status_idx on public.users (status);

-- Policies are defined in the access-control story. With RLS enabled and no
-- policies, the table is closed to client roles by default.
alter table public.users enable row level security;

-- ---------------------------------------------------------------------------
-- Rules enforced by triggers (section 9.1)
-- ---------------------------------------------------------------------------

-- Internal functions live outside the API-exposed schemas.
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

-- The application user behind the current session, or null for the system
-- (no session: migrations, seeds, dashboard SQL, Supabase Auth itself).
create function private.acting_user_id()
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select u.id from public.users u where u.auth_user_id = auth.uid();
$$;

create function private.is_system()
returns boolean
language sql
stable
set search_path = ''
as $$
  select auth.uid() is null;
$$;

create function private.users_enforce_rules()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor_id     uuid := private.acting_user_id();
  is_system    boolean := private.is_system();
  actor        public.users;
  login_email  text;
begin
  -- T1: sessions must belong to an ACTIVE ADMINISTRATOR.
  if not is_system then
    select * into actor from public.users where id = actor_id;
    if actor.id is null or actor.status <> 'ACTIVE' or actor.role <> 'ADMINISTRATOR' then
      raise exception 'Only an active administrator can create or change users'
        using errcode = '42501';
    end if;
  end if;

  if tg_op = 'INSERT' then
    -- T2: administrators can only create INVITED users.
    if not is_system and new.status <> 'INVITED' then
      raise exception 'New users must start as INVITED' using errcode = '23514';
    end if;

    -- T7: audit columns are set by the database.
    new.created_at := now();
    new.updated_at := now();
    new.created_by := actor_id;
    new.updated_by := actor_id;
  else
    -- T6: identity and creation audit never change.
    if new.id is distinct from old.id
       or new.created_at is distinct from old.created_at
       or new.created_by is distinct from old.created_by then
      raise exception 'id, created_at and created_by cannot be changed' using errcode = '42501';
    end if;

    -- T3: status transitions follow section 6.
    if new.status is distinct from old.status
       and not (old.status, new.status) in (
         ('INVITED',     'ACTIVE'),
         ('INVITED',     'DEACTIVATED'),
         ('ACTIVE',      'SUSPENDED'),
         ('SUSPENDED',   'ACTIVE'),
         ('ACTIVE',      'DEACTIVATED'),
         ('SUSPENDED',   'DEACTIVATED'),
         ('DEACTIVATED', 'ACTIVE'),
         ('DEACTIVATED', 'INVITED')
       ) then
      raise exception 'Status cannot change from % to %', old.status, new.status
        using errcode = '23514';
    end if;
    -- A returning user goes back to INVITED only if their login was removed;
    -- otherwise they return to ACTIVE.
    if old.status = 'DEACTIVATED' and new.status = 'INVITED' and new.auth_user_id is not null then
      raise exception 'A returning user with a linked login goes back to ACTIVE, not INVITED'
        using errcode = '23514';
    end if;

    -- T4: administrators cannot change their own status or role.
    if not is_system and old.id = actor_id
       and (new.status is distinct from old.status or new.role is distinct from old.role) then
      raise exception 'You cannot change your own status or role' using errcode = '42501';
    end if;

    -- T5: there must always be at least one ACTIVE ADMINISTRATOR.
    if old.status = 'ACTIVE' and old.role = 'ADMINISTRATOR'
       and (new.status <> 'ACTIVE' or new.role <> 'ADMINISTRATOR') then
      -- Serialize concurrent changes to administrators.
      perform pg_advisory_xact_lock(hashtext('public.users.active_administrators'));
      if not exists (
        select 1 from public.users
        where role = 'ADMINISTRATOR' and status = 'ACTIVE' and id <> old.id
      ) then
        raise exception 'The last active administrator cannot be suspended, deactivated or change role'
          using errcode = '23514';
      end if;
    end if;

    -- T7: audit columns are set by the database.
    new.updated_at := now();
    new.updated_by := actor_id;
  end if;

  -- T8: while a login is linked, email always equals the login email. The only
  -- way to change it is to change the login email (synced in 9.2).
  if new.auth_user_id is not null then
    select au.email into login_email from auth.users au where au.id = new.auth_user_id;
    if new.email is distinct from login_email::extensions.citext then
      raise exception 'Email must match the linked login email' using errcode = '23514';
    end if;
  end if;

  return new;
end;
$$;

create trigger users_enforce_rules
  before insert or update on public.users
  for each row execute function private.users_enforce_rules();

-- ---------------------------------------------------------------------------
-- Email sync, linking and activation (sections 9.2, 9.3)
-- ---------------------------------------------------------------------------

-- 9.3: a new login (e.g. from an invitation) is linked to the INVITED user with
-- the same email that has no login yet. Otherwise nothing is linked.
create function private.link_new_login()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.users
     set auth_user_id = new.id
   where email = new.email::extensions.citext
     and status = 'INVITED'
     and auth_user_id is null;
  return new;
end;
$$;

create trigger on_login_created
  after insert on auth.users
  for each row execute function private.link_new_login();

-- 9.3: accepting the invitation (email confirmed) moves INVITED to ACTIVE.
create function private.activate_on_confirmation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.users
     set status = 'ACTIVE'
   where auth_user_id = new.id
     and status = 'INVITED';
  return new;
end;
$$;

create trigger on_login_confirmed
  after update of email_confirmed_at on auth.users
  for each row
  when (old.email_confirmed_at is null and new.email_confirmed_at is not null)
  execute function private.activate_on_confirmation();

-- 9.2: a confirmed change of login email is copied onto the application user.
create function private.sync_login_email()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.users
     set email = new.email::extensions.citext
   where auth_user_id = new.id;
  return new;
end;
$$;

create trigger on_login_email_changed
  after update of email on auth.users
  for each row
  when (old.email is distinct from new.email)
  execute function private.sync_login_email();

revoke all on all functions in schema private from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- First administrator (section 5, Q5)
-- ---------------------------------------------------------------------------

-- Inserted by the system; invited from the Supabase dashboard afterwards.
insert into public.users (email, first_name, last_name, role)
values ('fkato1@umbc.edu', 'Francis', 'Kato', 'ADMINISTRATOR');

-- If a login with this email already exists, link it now (the insert trigger
-- above only sees logins created from here on), and activate it if confirmed.
update public.users u
   set auth_user_id = au.id
  from auth.users au
 where au.email::extensions.citext = u.email
   and u.email = 'fkato1@umbc.edu';

update public.users u
   set status = 'ACTIVE'
  from auth.users au
 where au.id = u.auth_user_id
   and au.email_confirmed_at is not null
   and u.email = 'fkato1@umbc.edu';
