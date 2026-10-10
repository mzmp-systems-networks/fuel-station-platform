-- Signed-in people can read their own application user and nothing else.
-- Run with: npx supabase test db
begin;
create extension if not exists pgtap with schema extensions;
select plan(4);

insert into auth.users (id, email)
values ('00000000-0000-0000-0000-00000000a001', 'fkato1@umbc.edu');

-- A second user, created by the system, with their own login.
insert into public.users (email, first_name, last_name, role)
values ('ann@example.com', 'Ann', 'Attendant', 'ATTENDANT');
insert into auth.users (id, email)
values ('00000000-0000-0000-0000-00000000a002', 'ann@example.com');

set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "00000000-0000-0000-0000-00000000a001", "role": "authenticated"}', true);

select results_eq(
  $$ select email::text from public.users $$,
  $$ values ('fkato1@umbc.edu') $$,
  'a signed-in person sees only their own application user'
);

select is_empty(
  $$ select 1 from public.users where email = 'ann@example.com' $$,
  'other users are not visible'
);

-- A login with no application user sees nothing.
select set_config('request.jwt.claims', '{"sub": "00000000-0000-0000-0000-00000000b001", "role": "authenticated"}', true);

select is_empty(
  $$ select 1 from public.users $$,
  'a login without an application user sees no users'
);

reset role;
set local role anon;
select set_config('request.jwt.claims', '', true);

select throws_ok(
  $$ select 1 from public.users $$,
  '42501', null,
  'anonymous requests cannot read users'
);

select * from finish();
rollback;
