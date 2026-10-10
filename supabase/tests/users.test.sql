-- Application users: persistence, retrieval and the rules in section 9.
-- Run with: npx supabase test db
begin;
create extension if not exists pgtap with schema extensions;
select plan(19);

-- Act as the system (no session), or as the login with the given auth ID.
create function pg_temp.act_as(auth_id uuid) returns void language sql as $$
  select set_config('request.jwt.claims',
    case when auth_id is null then '' else json_build_object('sub', auth_id)::text end, true);
$$;

-- ---------------------------------------------------------------------------
-- First administrator: seeded, linked on invitation, activated on acceptance
-- ---------------------------------------------------------------------------

select results_eq(
  $$ select first_name, last_name, role, status, created_by is null
       from public.users where email = 'FKATO1@umbc.edu' $$,
  $$ values ('Francis', 'Kato', 'ADMINISTRATOR', 'INVITED', true) $$,
  'first administrator is seeded as INVITED by the system (email is case-insensitive)'
);

insert into auth.users (id, email)
values ('00000000-0000-0000-0000-00000000a001', 'fkato1@umbc.edu');

select is(
  (select auth_user_id from public.users where email = 'fkato1@umbc.edu'),
  '00000000-0000-0000-0000-00000000a001'::uuid,
  'a new login is linked to the INVITED user with the same email'
);

update auth.users set email_confirmed_at = now()
 where id = '00000000-0000-0000-0000-00000000a001';

select is(
  (select status from public.users where email = 'fkato1@umbc.edu'),
  'ACTIVE',
  'accepting the invitation activates the user'
);

-- ---------------------------------------------------------------------------
-- An administrator creates and retrieves a user
-- ---------------------------------------------------------------------------

select pg_temp.act_as('00000000-0000-0000-0000-00000000a001');

insert into public.users (email, first_name, last_name, role, created_by, created_at)
values ('ann@example.com', 'Ann', 'Attendant', 'ATTENDANT',
        gen_random_uuid(), '2000-01-01');

select results_eq(
  $$ select u.first_name, u.last_name, u.role, u.status,
            u.created_by = a.id, u.updated_by = a.id, u.created_at > '2000-01-01'
       from public.users u, public.users a
      where u.email = 'ann@example.com' and a.email = 'fkato1@umbc.edu' $$,
  $$ values ('Ann', 'Attendant', 'ATTENDANT', 'INVITED', true, true, true) $$,
  'a created user is retrieved as INVITED with database-set audit columns'
);

select throws_ok(
  $$ insert into public.users (email, first_name, last_name, role, status)
     values ('bob@example.com', 'Bob', 'B', 'MANAGER', 'ACTIVE') $$,
  '23514', 'New users must start as INVITED',
  'T2: an administrator cannot create a user in another status'
);

-- ---------------------------------------------------------------------------
-- Constraints
-- ---------------------------------------------------------------------------

select throws_ok(
  $$ insert into public.users (email, first_name, last_name, role)
     values ('ANN@example.com', 'Ann', 'Two', 'ATTENDANT') $$,
  '23505', null, 'email is unique, case-insensitively'
);

select throws_ok(
  $$ insert into public.users (email, first_name, last_name)
     values ('norole@example.com', 'No', 'Role') $$,
  '23502', null, 'role is required'
);

select throws_ok(
  $$ insert into public.users (email, first_name, last_name, role)
     values ('owner@example.com', 'Ow', 'Ner', 'OWNER') $$,
  '23514', null, 'role must be one of the v1 roles'
);

select throws_ok(
  $$ insert into public.users (email, first_name, last_name, role)
     values ('blank@example.com', '  ', 'Name', 'ATTENDANT') $$,
  '23514', null, 'names cannot be blank'
);

select throws_ok(
  $$ insert into public.users (email, first_name, last_name, role)
     values ('not-an-email', 'Bad', 'Email', 'ATTENDANT') $$,
  '23514', null, 'email must look like an email'
);

-- ---------------------------------------------------------------------------
-- Rules on change
-- ---------------------------------------------------------------------------

select throws_ok(
  $$ update public.users set status = 'SUSPENDED' where email = 'ann@example.com' $$,
  '23514', 'Status cannot change from INVITED to SUSPENDED',
  'T3: transitions outside section 6 are rejected'
);

select throws_ok(
  $$ update public.users set status = 'DEACTIVATED' where email = 'fkato1@umbc.edu' $$,
  '42501', 'You cannot change your own status or role',
  'T4: an administrator cannot change their own status'
);

select throws_ok(
  $$ update public.users set id = gen_random_uuid() where email = 'ann@example.com' $$,
  '42501', 'id, created_at and created_by cannot be changed',
  'T6: id never changes'
);

select throws_ok(
  $$ update public.users set email = 'francis@example.com' where email = 'fkato1@umbc.edu' $$,
  '23514', 'Email must match the linked login email',
  'T8: a linked user''s email cannot be edited directly'
);

-- A login that is not an active administrator.
select pg_temp.act_as(gen_random_uuid());

select throws_ok(
  $$ update public.users set first_name = 'Annie' where email = 'ann@example.com' $$,
  '42501', 'Only an active administrator can create or change users',
  'T1: a session without an active administrator cannot change users'
);

-- As the system from here on.
select pg_temp.act_as(null);

select throws_ok(
  $$ update public.users set status = 'DEACTIVATED' where email = 'fkato1@umbc.edu' $$,
  '23514', 'The last active administrator cannot be suspended, deactivated or change role',
  'T5: the last active administrator cannot be deactivated, even by the system'
);

select throws_ok(
  $$ delete from auth.users where id = '00000000-0000-0000-0000-00000000a001' $$,
  '23514', null,
  'the login of an ACTIVE user cannot be removed'
);

update auth.users set email = 'francis.kato@example.com'
 where id = '00000000-0000-0000-0000-00000000a001';

select ok(
  exists (select 1 from public.users
           where auth_user_id = '00000000-0000-0000-0000-00000000a001'
             and email = 'francis.kato@example.com'),
  '9.2: a changed login email is copied onto the application user'
);

-- An uninvited sign-up is not linked to anyone.
insert into auth.users (id, email)
values ('00000000-0000-0000-0000-00000000b001', 'stranger@example.com');

select ok(
  not exists (select 1 from public.users
               where auth_user_id = '00000000-0000-0000-0000-00000000b001'),
  '9.3: a login with no matching INVITED user is not linked'
);

select * from finish();
rollback;
