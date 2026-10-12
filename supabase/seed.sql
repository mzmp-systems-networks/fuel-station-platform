-- Local sample data (npx supabase db reset). Never applied to the hosted
-- database: db push does not run seeds.
--
-- Nasuuti's pumps as drawn in the Sprint 2 plan. Pump and nozzle layout, meter
-- readings and prices are illustrative until confirmed with the owner.

insert into public.stations (code, name) values ('NASUUTI', 'Shell Nasuuti');

insert into public.product_prices (station_id, product_id, unit_price, effective_from)
select s.id, p.id, v.price, '2026-08-01'
  from (values ('PMS', 6530), ('AGO', 6440), ('VPOWER', 6705)) as v (code, price)
  join public.products p on p.code = v.code
  cross join public.stations s
 where s.code = 'NASUUTI';

insert into public.dispensers (station_id, label)
select s.id, v.label
  from (values ('Pump 1'), ('Pump 2')) as v (label)
  cross join public.stations s
 where s.code = 'NASUUTI';

insert into public.nozzles (dispenser_id, label, product_id, initial_meter)
select d.id, v.label, p.id, v.meter
  from (values ('Pump 1', 'P1', 'PMS',    1284503.2),
               ('Pump 1', 'D1', 'AGO',    612778.4),
               ('Pump 2', 'P2', 'PMS',    978341.9),
               ('Pump 2', 'V1', 'VPOWER', 41206.3)) as v (pump, label, code, meter)
  join public.dispensers d on d.label = v.pump
  join public.stations s on s.id = d.station_id and s.code = 'NASUUTI'
  join public.products p on p.code = v.code;
