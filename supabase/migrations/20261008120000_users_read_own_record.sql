-- Sign-in (Sprint 1, IAM): a signed-in person may read their own application
-- user, so Fuel ERP can apply the access rule (section 4 of
-- docs/sprint-1/application-user-model.md). Nothing else is readable yet.

-- Anonymous requests never reach user records, whatever the policies say.
revoke all on public.users from anon;
grant select on public.users to authenticated;

create policy users_select_own
  on public.users
  for select
  to authenticated
  using (auth_user_id = (select auth.uid()));
