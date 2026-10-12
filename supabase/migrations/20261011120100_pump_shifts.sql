-- Pump shifts (Sprint 2): an attendant works a pump, then hands over their
-- closing meters and the money they took. The database works out what they
-- sold and whether they are short or over.
--
-- Flow: a pump shift is assigned, the attendant starts it (opening meters are
-- copied from the last hand-over on each nozzle), then hands it over with
-- public.hand_over_pump_shift. Closing and approving the day come later.

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

-- A station's trading day. Pump shifts belong to one.
create table public.business_days (
  id            uuid primary key default gen_random_uuid(),
  station_id    uuid not null references public.stations (id) on delete restrict,
  business_date date not null,
  status        text not null default 'open',
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  created_by    uuid references public.users (id) on delete restrict,
  updated_by    uuid references public.users (id) on delete restrict,
  constraint business_days_station_date_key unique (station_id, business_date),
  constraint business_days_status_valid check (status in ('open', 'closed', 'approved'))
);

-- One attendant on one pump for one stretch of time. Two attendants on the same
-- pump in a day are two rows.
create table public.pump_shifts (
  id              uuid primary key default gen_random_uuid(),
  business_day_id uuid not null references public.business_days (id) on delete restrict,
  station_id      uuid not null references public.stations (id) on delete restrict,
  dispenser_id    uuid not null references public.dispensers (id) on delete restrict,
  attendant_id    uuid not null references public.users (id) on delete restrict,
  label           text,
  status          text not null default 'assigned',
  -- Set by the database when the shift starts and when it is handed over.
  started_at      timestamptz,
  ended_at        timestamptz,
  variance_reason text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  created_by      uuid references public.users (id) on delete restrict,
  updated_by      uuid references public.users (id) on delete restrict,
  constraint pump_shifts_status_valid check (status in ('assigned', 'on_duty', 'handed_over', 'approved')),
  constraint pump_shifts_times_match_status check (
    (status = 'assigned' and started_at is null and ended_at is null)
    or (status = 'on_duty' and started_at is not null and ended_at is null)
    or (status in ('handed_over', 'approved') and started_at is not null and ended_at is not null
        and ended_at >= started_at)
  )
);

-- One attendant on a pump at a time.
create unique index pump_shifts_one_on_duty_per_dispenser
  on public.pump_shifts (dispenser_id) where status = 'on_duty';
create index pump_shifts_business_day_id_idx on public.pump_shifts (business_day_id);
create index pump_shifts_attendant_id_idx on public.pump_shifts (attendant_id);

-- Opening and closing meter of each nozzle on the pump, for one pump shift.
-- The price is copied in when the shift starts, so a later price change cannot
-- rewrite what was sold.
create table public.nozzle_readings (
  id            uuid primary key default gen_random_uuid(),
  pump_shift_id uuid not null references public.pump_shifts (id) on delete restrict,
  nozzle_id     uuid not null references public.nozzles (id) on delete restrict,
  opening       numeric(14, 2) not null,
  closing       numeric(14, 2),
  unit_price    numeric(12, 2) not null,
  litres        numeric(14, 2) generated always as (closing - opening) stored,
  amount        numeric(14, 2) generated always as (round((closing - opening) * unit_price, 2)) stored,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  created_by    uuid references public.users (id) on delete restrict,
  updated_by    uuid references public.users (id) on delete restrict,
  constraint nozzle_readings_shift_nozzle_key unique (pump_shift_id, nozzle_id),
  constraint nozzle_readings_closing_not_below_opening check (closing is null or closing >= opening),
  constraint nozzle_readings_unit_price_positive check (unit_price > 0)
);

create index nozzle_readings_nozzle_id_idx on public.nozzle_readings (nozzle_id);

-- What the attendant took, one total per payment method. Cash handed in is the
-- cash method.
create table public.pump_shift_payments (
  id                uuid primary key default gen_random_uuid(),
  pump_shift_id     uuid not null references public.pump_shifts (id) on delete restrict,
  payment_method_id uuid not null references public.payment_methods (id) on delete restrict,
  amount            numeric(14, 2) not null,
  reference         text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  created_by        uuid references public.users (id) on delete restrict,
  updated_by        uuid references public.users (id) on delete restrict,
  constraint pump_shift_payments_shift_method_key unique (pump_shift_id, payment_method_id),
  constraint pump_shift_payments_amount_valid check (amount >= 0)
);

-- ---------------------------------------------------------------------------
-- Sold, handed in, short or over
-- ---------------------------------------------------------------------------

-- variance > 0: over; variance < 0: short. Callers see only the shifts their
-- policies allow (security_invoker).
create view public.pump_shift_totals
with (security_invoker = true)
as
select s.id as pump_shift_id,
       r.sold,
       p.handed_in,
       p.handed_in - r.sold as variance
  from public.pump_shifts s
 cross join lateral (
   select coalesce(sum(nr.amount), 0) as sold
     from public.nozzle_readings nr
    where nr.pump_shift_id = s.id
 ) r
 cross join lateral (
   select coalesce(sum(sp.amount), 0) as handed_in
     from public.pump_shift_payments sp
    where sp.pump_shift_id = s.id
 ) p;

-- ---------------------------------------------------------------------------
-- Rules enforced by triggers
-- ---------------------------------------------------------------------------

create function private.pump_shifts_enforce_rules()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  day_station_id       uuid;
  day_status           text;
  dispenser_station_id uuid;
  shift_variance       numeric;
  variance_limit       numeric;
begin
  select station_id, status into day_station_id, day_status
    from public.business_days where id = new.business_day_id;
  select station_id into dispenser_station_id
    from public.dispensers where id = new.dispenser_id;

  if day_station_id is distinct from new.station_id
     or dispenser_station_id is distinct from new.station_id then
    raise exception 'The pump and the business day must belong to the shift''s station'
      using errcode = '23514';
  end if;

  if tg_op = 'INSERT' then
    if new.status <> 'assigned' then
      raise exception 'A pump shift starts as assigned' using errcode = '23514';
    end if;
    new.started_at := null;
    new.ended_at := null;
    return new;
  end if;

  if new.status is distinct from old.status
     and not (old.status, new.status) in (
       ('assigned',    'on_duty'),
       ('on_duty',     'handed_over'),
       ('handed_over', 'approved')
     ) then
    raise exception 'Pump shift status cannot change from % to %', old.status, new.status
      using errcode = '23514';
  end if;

  if old.status <> 'assigned'
     and (new.business_day_id, new.station_id, new.dispenser_id, new.attendant_id)
         is distinct from (old.business_day_id, old.station_id, old.dispenser_id, old.attendant_id) then
    raise exception 'The day, pump and attendant cannot change once a shift has started'
      using errcode = '42501';
  end if;

  -- Start and end times are set by the database only.
  new.started_at := old.started_at;
  new.ended_at := old.ended_at;

  if old.status = 'assigned' and new.status = 'on_duty' then
    if day_status <> 'open' then
      raise exception 'The business day is not open' using errcode = '23514';
    end if;
    new.started_at := now();

  elsif old.status = 'on_duty' and new.status = 'handed_over' then
    if day_status <> 'open' then
      raise exception 'The business day is not open' using errcode = '23514';
    end if;
    if exists (select 1 from public.nozzle_readings
                where pump_shift_id = new.id and closing is null) then
      raise exception 'Enter a closing meter for every nozzle' using errcode = '23514';
    end if;
    select t.variance into shift_variance
      from public.pump_shift_totals t where t.pump_shift_id = new.id;
    select cash_variance_limit into variance_limit
      from public.stations where id = new.station_id;
    if abs(shift_variance) > variance_limit
       and coalesce(btrim(new.variance_reason), '') = '' then
      raise exception 'Give a reason: you are short or over by more than the station''s limit'
        using errcode = '23514';
    end if;
    new.ended_at := now();
  end if;

  return new;
end;
$$;

create trigger pump_shifts_enforce_rules
  before insert or update on public.pump_shifts
  for each row execute function private.pump_shifts_enforce_rules();

-- When a shift starts: one reading per active nozzle on the pump. The opening
-- meter is the last hand-over's closing meter on that nozzle (meters only go
-- up), or the nozzle's initial meter if it has never been handed over.
create function private.pump_shifts_open_readings()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  unpriced text;
begin
  if not exists (select 1 from public.nozzles where dispenser_id = new.dispenser_id and active) then
    raise exception 'This pump has no active nozzles' using errcode = '23514';
  end if;

  select string_agg(p.code, ', ') into unpriced
    from public.nozzles n
    join public.products p on p.id = n.product_id
   where n.dispenser_id = new.dispenser_id and n.active
     and not exists (select 1 from public.product_prices pp
                      where pp.station_id = new.station_id and pp.product_id = n.product_id
                        and pp.effective_from <= now());
  if unpriced is not null then
    raise exception 'No price is set for %', unpriced using errcode = '23514';
  end if;

  insert into public.nozzle_readings (pump_shift_id, nozzle_id, opening, unit_price)
  select new.id,
         n.id,
         coalesce(
           (select r.closing
              from public.nozzle_readings r
              join public.pump_shifts s on s.id = r.pump_shift_id
             where r.nozzle_id = n.id
               and r.closing is not null
               and s.status in ('handed_over', 'approved')
             order by s.ended_at desc, r.closing desc
             limit 1),
           n.initial_meter),
         (select pp.unit_price
            from public.product_prices pp
           where pp.station_id = new.station_id and pp.product_id = n.product_id
             and pp.effective_from <= now()
           order by pp.effective_from desc
           limit 1)
    from public.nozzles n
   where n.dispenser_id = new.dispenser_id and n.active;

  return null;
end;
$$;

create trigger pump_shifts_open_readings
  after update of status on public.pump_shifts
  for each row
  when (old.status = 'assigned' and new.status = 'on_duty')
  execute function private.pump_shifts_open_readings();

-- Meters and payments change only while the shift is on duty (the system may
-- still correct them).
create function private.pump_shift_entries_enforce_rules()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  shift_id     uuid;
  shift_status text;
begin
  if tg_op = 'DELETE' then
    shift_id := old.pump_shift_id;
  else
    shift_id := new.pump_shift_id;
  end if;

  if not private.is_system() then
    select status into shift_status from public.pump_shifts where id = shift_id;
    if shift_status is distinct from 'on_duty' then
      raise exception 'Meters and payments can only be changed while the shift is on duty'
        using errcode = '42501';
    end if;
    if tg_op = 'UPDATE' and new.pump_shift_id is distinct from old.pump_shift_id then
      raise exception 'An entry cannot move to another shift' using errcode = '42501';
    end if;
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

-- Readings are created by the database when a shift starts, so only updates
-- are checked; attendants have no insert grant.
create trigger nozzle_readings_enforce_rules
  before update on public.nozzle_readings
  for each row execute function private.pump_shift_entries_enforce_rules();
create trigger pump_shift_payments_enforce_rules
  before insert or update or delete on public.pump_shift_payments
  for each row execute function private.pump_shift_entries_enforce_rules();

create trigger business_days_audit before insert or update on public.business_days
  for each row execute function private.set_audit_columns();
create trigger pump_shifts_audit before insert or update on public.pump_shifts
  for each row execute function private.set_audit_columns();
create trigger nozzle_readings_audit before insert or update on public.nozzle_readings
  for each row execute function private.set_audit_columns();
create trigger pump_shift_payments_audit before insert or update on public.pump_shift_payments
  for each row execute function private.set_audit_columns();

revoke all on all functions in schema private from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Hand-over
-- ---------------------------------------------------------------------------

-- The attendant's hand-over, in one transaction: closing meters keyed by nozzle
-- id, payments keyed by payment method code (amounts in UGX), and a reason when
-- short or over beyond the station's limit. Runs as the caller, so the policies
-- and triggers above apply.
--
--   select * from hand_over_pump_shift(
--     '<pump shift id>',
--     '{"<nozzle id>": 1286607.8, "<nozzle id>": 613676.9}',
--     '{"cash": 6668114, "shell_card": 700000, "mtn_momo": 600000}',
--     'Customer change kept back');
create function public.hand_over_pump_shift(
  p_pump_shift_id   uuid,
  p_closing_meters  jsonb,
  p_payments        jsonb,
  p_variance_reason text default null
)
returns public.pump_shift_totals
language plpgsql
security invoker
set search_path = ''
as $$
declare
  unknown_method text;
  result         public.pump_shift_totals;
begin
  if not exists (
    select 1 from public.pump_shifts s
     where s.id = p_pump_shift_id
       and s.status = 'on_duty'
       and s.attendant_id = (select u.id from public.users u where u.auth_user_id = (select auth.uid()))
  ) then
    raise exception 'This shift is not on duty, or it is not yours' using errcode = '42501';
  end if;

  select k into unknown_method
    from jsonb_object_keys(coalesce(p_payments, '{}')) k
   where not exists (select 1 from public.payment_methods pm where pm.code = k and pm.active)
   limit 1;
  if unknown_method is not null then
    raise exception 'Unknown payment method: %', unknown_method using errcode = '22023';
  end if;

  update public.nozzle_readings r
     set closing = m.value::numeric
    from jsonb_each_text(coalesce(p_closing_meters, '{}')) m
   where r.pump_shift_id = p_pump_shift_id
     and r.nozzle_id = m.key::uuid;

  delete from public.pump_shift_payments where pump_shift_id = p_pump_shift_id;
  insert into public.pump_shift_payments (pump_shift_id, payment_method_id, amount)
  select p_pump_shift_id, pm.id, e.value::numeric
    from jsonb_each_text(coalesce(p_payments, '{}')) e
    join public.payment_methods pm on pm.code = e.key
   where e.value::numeric > 0;

  update public.pump_shifts
     set status = 'handed_over',
         variance_reason = nullif(btrim(p_variance_reason), '')
   where id = p_pump_shift_id;

  select * into result from public.pump_shift_totals where pump_shift_id = p_pump_shift_id;
  return result;
end;
$$;

revoke all on function public.hand_over_pump_shift(uuid, jsonb, jsonb, text) from public, anon;
grant execute on function public.hand_over_pump_shift(uuid, jsonb, jsonb, text) to authenticated;

-- ---------------------------------------------------------------------------
-- Access
-- ---------------------------------------------------------------------------

-- Who sees a pump shift: its attendant, an administrator, or a manager assigned
-- to its station. Attendants change only their own shift: start it, hand it
-- over, and enter its meters and payments while it is on duty. Assigning
-- shifts is done by the system until the assign screen exists.

revoke all on public.business_days, public.pump_shifts, public.nozzle_readings,
  public.pump_shift_payments, public.pump_shift_totals
  from anon, authenticated;
grant select on public.business_days, public.pump_shifts, public.nozzle_readings,
  public.pump_shift_payments, public.pump_shift_totals
  to authenticated;
grant update (status, variance_reason) on public.pump_shifts to authenticated;
grant update (closing) on public.nozzle_readings to authenticated;
grant insert (pump_shift_id, payment_method_id, amount, reference),
      update (amount, reference),
      delete
  on public.pump_shift_payments to authenticated;

alter table public.business_days       enable row level security;
alter table public.pump_shifts         enable row level security;
alter table public.nozzle_readings     enable row level security;
alter table public.pump_shift_payments enable row level security;

create policy business_days_select_station on public.business_days for select to authenticated
  using (exists (
    select 1 from public.users u
     where u.auth_user_id = (select auth.uid()) and u.status = 'ACTIVE'
       and (u.role = 'ADMINISTRATOR'
            or exists (select 1 from public.user_stations us
                        where us.user_id = u.id and us.station_id = business_days.station_id))
  ));

create policy pump_shifts_select_visible on public.pump_shifts for select to authenticated
  using (exists (
    select 1 from public.users u
     where u.auth_user_id = (select auth.uid()) and u.status = 'ACTIVE'
       and (u.id = pump_shifts.attendant_id
            or u.role = 'ADMINISTRATOR'
            or (u.role = 'MANAGER'
                and exists (select 1 from public.user_stations us
                             where us.user_id = u.id and us.station_id = pump_shifts.station_id)))
  ));

create policy pump_shifts_update_own on public.pump_shifts for update to authenticated
  using (
    status in ('assigned', 'on_duty')
    and attendant_id = (select u.id from public.users u
                         where u.auth_user_id = (select auth.uid()) and u.status = 'ACTIVE')
  )
  with check (
    attendant_id = (select u.id from public.users u
                     where u.auth_user_id = (select auth.uid()) and u.status = 'ACTIVE')
  );

-- Readings and payments follow the visibility of their shift.
create policy nozzle_readings_select_visible on public.nozzle_readings for select to authenticated
  using (exists (select 1 from public.pump_shifts s where s.id = nozzle_readings.pump_shift_id));

create policy nozzle_readings_update_own on public.nozzle_readings for update to authenticated
  using (exists (
    select 1 from public.pump_shifts s
     where s.id = nozzle_readings.pump_shift_id and s.status = 'on_duty'
       and s.attendant_id = (select u.id from public.users u
                              where u.auth_user_id = (select auth.uid()) and u.status = 'ACTIVE')
  ));

create policy pump_shift_payments_select_visible on public.pump_shift_payments for select to authenticated
  using (exists (select 1 from public.pump_shifts s where s.id = pump_shift_payments.pump_shift_id));

create policy pump_shift_payments_insert_own on public.pump_shift_payments for insert to authenticated
  with check (exists (
    select 1 from public.pump_shifts s
     where s.id = pump_shift_payments.pump_shift_id and s.status = 'on_duty'
       and s.attendant_id = (select u.id from public.users u
                              where u.auth_user_id = (select auth.uid()) and u.status = 'ACTIVE')
  ));

create policy pump_shift_payments_update_own on public.pump_shift_payments for update to authenticated
  using (exists (
    select 1 from public.pump_shifts s
     where s.id = pump_shift_payments.pump_shift_id and s.status = 'on_duty'
       and s.attendant_id = (select u.id from public.users u
                              where u.auth_user_id = (select auth.uid()) and u.status = 'ACTIVE')
  ));

create policy pump_shift_payments_delete_own on public.pump_shift_payments for delete to authenticated
  using (exists (
    select 1 from public.pump_shifts s
     where s.id = pump_shift_payments.pump_shift_id and s.status = 'on_duty'
       and s.attendant_id = (select u.id from public.users u
                              where u.auth_user_id = (select auth.uid()) and u.status = 'ACTIVE')
  ));
