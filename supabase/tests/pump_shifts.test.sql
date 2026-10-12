-- Pump shifts: an attendant starts a shift on a pump, hands over their meters
-- and money, and the next attendant opens from their closing meters.
-- Figures are Joseph's evening on Pump 1 at Nasuuti, 8 Aug 2026.
-- Run with: npx supabase test db
begin;
create extension if not exists pgtap with schema extensions;
select plan(17);

-- ---------------------------------------------------------------------------
-- Setup, as the system
-- ---------------------------------------------------------------------------

insert into public.stations (id, code, name, cash_variance_limit)
values ('10000000-0000-0000-0000-000000000001', 'TEST_STATION', 'Test station', 10000);

insert into public.product_prices (station_id, product_id, unit_price, effective_from)
select '10000000-0000-0000-0000-000000000001', p.id, v.price, '2026-01-01'
  from (values ('PMS', 6530), ('AGO', 6440)) as v (code, price)
  join public.products p on p.code = v.code;

insert into public.dispensers (id, station_id, label)
values ('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'Pump 1');

insert into public.nozzles (id, dispenser_id, label, product_id, initial_meter)
select v.id::uuid, '20000000-0000-0000-0000-000000000001', v.label, p.id, v.meter
  from (values ('30000000-0000-0000-0000-000000000001', 'P1', 'PMS', 1285640.0),
               ('30000000-0000-0000-0000-000000000002', 'D1', 'AGO', 613262.4)) as v (id, label, code, meter)
  join public.products p on p.code = v.code;

-- Two attendants and a manager, each with an accepted login (so ACTIVE).
insert into public.users (email, first_name, last_name, role) values
  ('joseph@example.com', 'Joseph', 'K', 'ATTENDANT'),
  ('peter@example.com',  'Peter',  'O', 'ATTENDANT'),
  ('mgr@example.com',    'Mary',   'M', 'MANAGER');
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-00000000a101', 'joseph@example.com'),
  ('00000000-0000-0000-0000-00000000a102', 'peter@example.com'),
  ('00000000-0000-0000-0000-00000000a103', 'mgr@example.com');
update auth.users set email_confirmed_at = now()
 where id in ('00000000-0000-0000-0000-00000000a101',
              '00000000-0000-0000-0000-00000000a102',
              '00000000-0000-0000-0000-00000000a103');

insert into public.user_stations (user_id, station_id)
select u.id, '10000000-0000-0000-0000-000000000001'
  from public.users u
 where u.email in ('joseph@example.com', 'peter@example.com', 'mgr@example.com');

insert into public.business_days (id, station_id, business_date)
values ('40000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '2026-08-08');

-- Joseph, then Peter, on Pump 1.
insert into public.pump_shifts (id, business_day_id, station_id, dispenser_id, attendant_id, label)
select v.id::uuid, '40000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001',
       '20000000-0000-0000-0000-000000000001', u.id, v.label
  from (values ('50000000-0000-0000-0000-000000000001', 'joseph@example.com', 'Evening'),
               ('50000000-0000-0000-0000-000000000002', 'peter@example.com',  'Night')) as v (id, email, label)
  join public.users u on u.email = v.email;

-- ---------------------------------------------------------------------------
-- Joseph starts his shift
-- ---------------------------------------------------------------------------

set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "00000000-0000-0000-0000-00000000a101", "role": "authenticated"}', true);

select is(
  (select count(*)::int from public.pump_shifts), 1,
  'an attendant sees only their own pump shift'
);

update public.pump_shifts set status = 'on_duty' where id = '50000000-0000-0000-0000-000000000001';

select results_eq(
  $$ select nozzle_id, opening, unit_price from public.nozzle_readings order by opening $$,
  $$ values ('30000000-0000-0000-0000-000000000002'::uuid, 613262.40, 6440.00),
            ('30000000-0000-0000-0000-000000000001'::uuid, 1285640.00, 6530.00) $$,
  'starting a shift opens each nozzle from its last meter, at today''s price'
);

select results_eq(
  $$ select status, started_at is not null from public.pump_shifts
      where id = '50000000-0000-0000-0000-000000000001' $$,
  $$ values ('on_duty', true) $$,
  'the shift is on duty with a start time set by the database'
);

-- Peter tries to start on the same pump while Joseph is on it.
select set_config('request.jwt.claims', '{"sub": "00000000-0000-0000-0000-00000000a102", "role": "authenticated"}', true);

select throws_ok(
  $$ update public.pump_shifts set status = 'on_duty' where id = '50000000-0000-0000-0000-000000000002' $$,
  '23505', null,
  'only one attendant can be on a pump at a time'
);

-- ---------------------------------------------------------------------------
-- Joseph hands over
-- ---------------------------------------------------------------------------

select set_config('request.jwt.claims', '{"sub": "00000000-0000-0000-0000-00000000a101", "role": "authenticated"}', true);

select throws_ok(
  $$ update public.nozzle_readings set opening = 0 $$,
  '42501', null,
  'an attendant cannot change an opening meter'
);

select throws_ok(
  $$ select * from public.hand_over_pump_shift(
       '50000000-0000-0000-0000-000000000001',
       '{"30000000-0000-0000-0000-000000000001": 1285000.0, "30000000-0000-0000-0000-000000000002": 613676.9}',
       '{"cash": 6668114}') $$,
  '23514', null,
  'a closing meter cannot be below the opening meter'
);

select throws_ok(
  $$ select * from public.hand_over_pump_shift(
       '50000000-0000-0000-0000-000000000001',
       '{"30000000-0000-0000-0000-000000000001": 1286607.8, "30000000-0000-0000-0000-000000000002": 613676.9}',
       '{"cash": 6668114, "shell_card": 700000, "uba_card": 344000, "mtn_momo": 600000, "airtel_money": 700000}') $$,
  '23514', 'Give a reason: you are short or over by more than the station''s limit',
  'over by more than the limit needs a reason'
);

-- PMS 967.8 L x 6,530 + AGO 414.5 L x 6,440 = 8,989,114 sold; 9,012,114 handed in.
select results_eq(
  $$ select sold, handed_in, variance from public.hand_over_pump_shift(
       '50000000-0000-0000-0000-000000000001',
       '{"30000000-0000-0000-0000-000000000001": 1286607.8, "30000000-0000-0000-0000-000000000002": 613676.9}',
       '{"cash": 6668114, "shell_card": 700000, "uba_card": 344000, "mtn_momo": 600000, "airtel_money": 700000}',
       'Customer change kept back') $$,
  $$ values (8989114.00, 9012114.00, 23000.00) $$,
  'hand-over returns what was sold, what was handed in, and the 23,000 over'
);

select results_eq(
  $$ select status, ended_at is not null, variance_reason from public.pump_shifts
      where id = '50000000-0000-0000-0000-000000000001' $$,
  $$ values ('handed_over', true, 'Customer change kept back') $$,
  'the shift is handed over with an end time and the reason'
);

select throws_ok(
  $$ select * from public.hand_over_pump_shift(
       '50000000-0000-0000-0000-000000000001', '{}', '{"cash": 1}') $$,
  '42501', 'This shift is not on duty, or it is not yours',
  'a shift cannot be handed over twice'
);

-- After hand-over, Joseph's payments no longer match his update (checked below).
update public.pump_shift_payments set amount = 1;

-- ---------------------------------------------------------------------------
-- Peter takes over the pump
-- ---------------------------------------------------------------------------

select set_config('request.jwt.claims', '{"sub": "00000000-0000-0000-0000-00000000a102", "role": "authenticated"}', true);

update public.pump_shifts set status = 'on_duty' where id = '50000000-0000-0000-0000-000000000002';

select results_eq(
  $$ select nozzle_id, opening from public.nozzle_readings order by opening $$,
  $$ values ('30000000-0000-0000-0000-000000000002'::uuid, 613676.90),
            ('30000000-0000-0000-0000-000000000001'::uuid, 1286607.80) $$,
  'the next attendant opens from the last hand-over''s closing meters'
);

select results_eq(
  $$ select (select count(*)::int from public.pump_shifts),
            (select count(*)::int from public.nozzle_readings) $$,
  $$ values (1, 2) $$,
  'the next attendant does not see the previous attendant''s shift or meters'
);

select throws_ok(
  $$ select * from public.hand_over_pump_shift(
       '50000000-0000-0000-0000-000000000002', '{}', '{"bitcoin": 5}') $$,
  '22023', 'Unknown payment method: bitcoin',
  'an unknown payment method is rejected'
);

-- ---------------------------------------------------------------------------
-- The manager sees both shifts
-- ---------------------------------------------------------------------------

select set_config('request.jwt.claims', '{"sub": "00000000-0000-0000-0000-00000000a103", "role": "authenticated"}', true);

select results_eq(
  $$ select t.pump_shift_id, t.variance from public.pump_shift_totals t order by t.pump_shift_id $$,
  $$ values ('50000000-0000-0000-0000-000000000001'::uuid, 23000.00),
            ('50000000-0000-0000-0000-000000000002'::uuid, 0.00) $$,
  'a manager sees every pump shift at their station, with totals'
);

reset role;
set local role anon;
select set_config('request.jwt.claims', '', true);

select throws_ok(
  $$ select 1 from public.pump_shifts $$,
  '42501', null,
  'anonymous requests cannot read pump shifts'
);

-- ---------------------------------------------------------------------------
-- As the system again
-- ---------------------------------------------------------------------------

reset role;

select results_eq(
  $$ select p.amount, p.created_by = u.id
       from public.pump_shift_payments p
       join public.payment_methods m on m.id = p.payment_method_id
       join public.users u on u.email = 'joseph@example.com'
      where p.pump_shift_id = '50000000-0000-0000-0000-000000000001' and m.code = 'cash' $$,
  $$ values (6668114.00, true) $$,
  'payments are recorded against the attendant and locked after hand-over'
);

select throws_ok(
  $$ insert into public.pump_shifts (business_day_id, station_id, dispenser_id, attendant_id, status)
     select '40000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001',
            '20000000-0000-0000-0000-000000000001', u.id, 'on_duty'
       from public.users u where u.email = 'peter@example.com' $$,
  '23514', 'A pump shift starts as assigned',
  'a new pump shift starts as assigned'
);

select * from finish();
rollback;
