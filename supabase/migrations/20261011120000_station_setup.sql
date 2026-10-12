-- Station setup (Sprint 2): the catalogue, prices, payment methods and pump
-- equipment that pump shifts are recorded against.
--
-- Fuel and later shop items, LPG or car wash share one catalogue: anything that
-- can grow (departments, units, products, payment methods) is a row, so adding
-- one needs no migration. Rules follow the user model (D9): enforced here, in
-- the database, with audit columns set from the session.

-- ---------------------------------------------------------------------------
-- Audit columns
-- ---------------------------------------------------------------------------

-- created_* never change; updated_* are set on every change; the user comes from
-- the session (null for the system).
create function private.set_audit_columns()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    new.created_at := now();
    new.created_by := private.acting_user_id();
  else
    new.created_at := old.created_at;
    new.created_by := old.created_by;
  end if;
  new.updated_at := now();
  new.updated_by := private.acting_user_id();
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- Stations and who works at them
-- ---------------------------------------------------------------------------

create table public.stations (
  id                  uuid primary key default gen_random_uuid(),
  code                text not null,
  name                text not null,
  -- A pump shift short or over by more than this needs a reason (UGX).
  cash_variance_limit numeric(14, 2) not null default 10000,
  active              boolean not null default true,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  created_by          uuid references public.users (id) on delete restrict,
  updated_by          uuid references public.users (id) on delete restrict,
  constraint stations_code_key unique (code),
  constraint stations_code_format check (code ~ '^[A-Z0-9_]+$'),
  constraint stations_name_not_blank check (length(btrim(name)) > 0),
  constraint stations_cash_variance_limit_valid check (cash_variance_limit >= 0)
);

-- Which stations a user works at (user model, section 8). Administrators see
-- every station without a row here.
create table public.user_stations (
  user_id    uuid not null references public.users (id) on delete restrict,
  station_id uuid not null references public.stations (id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid references public.users (id) on delete restrict,
  updated_by uuid references public.users (id) on delete restrict,
  primary key (user_id, station_id)
);

-- ---------------------------------------------------------------------------
-- Catalogue
-- ---------------------------------------------------------------------------

create table public.units (
  code       text primary key,
  name       text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid references public.users (id) on delete restrict,
  updated_by uuid references public.users (id) on delete restrict,
  constraint units_code_not_blank check (length(btrim(code)) > 0),
  constraint units_name_not_blank check (length(btrim(name)) > 0)
);

create table public.departments (
  id         uuid primary key default gen_random_uuid(),
  code       text not null,
  name       text not null,
  parent_id  uuid references public.departments (id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid references public.users (id) on delete restrict,
  updated_by uuid references public.users (id) on delete restrict,
  constraint departments_code_key unique (code),
  constraint departments_code_format check (code ~ '^[A-Z0-9_]+$'),
  constraint departments_name_not_blank check (length(btrim(name)) > 0)
);

create table public.products (
  id            uuid primary key default gen_random_uuid(),
  code          text not null,
  name          text not null,
  department_id uuid not null references public.departments (id) on delete restrict,
  unit_code     text not null references public.units (code) on delete restrict,
  kind          text not null,
  track_stock   boolean not null default true,
  active        boolean not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  created_by    uuid references public.users (id) on delete restrict,
  updated_by    uuid references public.users (id) on delete restrict,
  constraint products_code_key unique (code),
  constraint products_code_format check (code ~ '^[A-Z0-9_]+$'),
  constraint products_name_not_blank check (length(btrim(name)) > 0),
  constraint products_kind_valid check (kind in ('fuel', 'stock_item', 'non_stock_item', 'service', 'deposit')),
  -- Services and non-stock items have no stock to track.
  constraint products_stockless_kinds check (kind not in ('service', 'non_stock_item') or not track_stock)
);

create index products_department_id_idx on public.products (department_id);

-- A price applies from effective_from until the next one for the same station
-- and product. Prices are not regulated in Uganda and change often.
create table public.product_prices (
  id             uuid primary key default gen_random_uuid(),
  station_id     uuid not null references public.stations (id) on delete restrict,
  product_id     uuid not null references public.products (id) on delete restrict,
  unit_price     numeric(12, 2) not null,
  effective_from timestamptz not null,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  created_by     uuid references public.users (id) on delete restrict,
  updated_by     uuid references public.users (id) on delete restrict,
  constraint product_prices_station_product_from_key unique (station_id, product_id, effective_from),
  constraint product_prices_unit_price_positive check (unit_price > 0)
);

create table public.payment_methods (
  id         uuid primary key default gen_random_uuid(),
  code       text not null,
  name       text not null,
  type       text not null,
  active     boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid references public.users (id) on delete restrict,
  updated_by uuid references public.users (id) on delete restrict,
  constraint payment_methods_code_key unique (code),
  constraint payment_methods_code_format check (code ~ '^[a-z0-9_]+$'),
  constraint payment_methods_name_not_blank check (length(btrim(name)) > 0),
  constraint payment_methods_type_valid check (type in ('cash', 'card', 'mobile_money', 'fleet_card'))
);

-- ---------------------------------------------------------------------------
-- Pump equipment
-- ---------------------------------------------------------------------------

-- A pump (dispenser) at a station. Attendants are assigned to pumps.
create table public.dispensers (
  id         uuid primary key default gen_random_uuid(),
  station_id uuid not null references public.stations (id) on delete restrict,
  label      text not null,
  active     boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid references public.users (id) on delete restrict,
  updated_by uuid references public.users (id) on delete restrict,
  constraint dispensers_station_label_key unique (station_id, label),
  constraint dispensers_label_not_blank check (length(btrim(label)) > 0)
);

-- A nozzle on a pump, selling one product. initial_meter is the meter reading
-- when the nozzle was set up; the first pump shift opens from it.
create table public.nozzles (
  id            uuid primary key default gen_random_uuid(),
  dispenser_id  uuid not null references public.dispensers (id) on delete restrict,
  label         text not null,
  product_id    uuid not null references public.products (id) on delete restrict,
  initial_meter numeric(14, 2) not null default 0,
  active        boolean not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  created_by    uuid references public.users (id) on delete restrict,
  updated_by    uuid references public.users (id) on delete restrict,
  constraint nozzles_dispenser_label_key unique (dispenser_id, label),
  constraint nozzles_label_not_blank check (length(btrim(label)) > 0),
  constraint nozzles_initial_meter_valid check (initial_meter >= 0)
);

create index nozzles_product_id_idx on public.nozzles (product_id);

-- ---------------------------------------------------------------------------
-- Audit triggers
-- ---------------------------------------------------------------------------

create trigger stations_audit before insert or update on public.stations
  for each row execute function private.set_audit_columns();
create trigger user_stations_audit before insert or update on public.user_stations
  for each row execute function private.set_audit_columns();
create trigger units_audit before insert or update on public.units
  for each row execute function private.set_audit_columns();
create trigger departments_audit before insert or update on public.departments
  for each row execute function private.set_audit_columns();
create trigger products_audit before insert or update on public.products
  for each row execute function private.set_audit_columns();
create trigger product_prices_audit before insert or update on public.product_prices
  for each row execute function private.set_audit_columns();
create trigger payment_methods_audit before insert or update on public.payment_methods
  for each row execute function private.set_audit_columns();
create trigger dispensers_audit before insert or update on public.dispensers
  for each row execute function private.set_audit_columns();
create trigger nozzles_audit before insert or update on public.nozzles
  for each row execute function private.set_audit_columns();

revoke all on all functions in schema private from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Access
-- ---------------------------------------------------------------------------

-- Setup is changed by the system (migrations, dashboard SQL) until the admin
-- screens exist. Any active user may read it.
revoke all on public.stations, public.user_stations, public.units, public.departments,
  public.products, public.product_prices, public.payment_methods, public.dispensers,
  public.nozzles
  from anon, authenticated;
grant select on public.stations, public.user_stations, public.units, public.departments,
  public.products, public.product_prices, public.payment_methods, public.dispensers,
  public.nozzles
  to authenticated;

alter table public.stations        enable row level security;
alter table public.user_stations   enable row level security;
alter table public.units           enable row level security;
alter table public.departments     enable row level security;
alter table public.products        enable row level security;
alter table public.product_prices  enable row level security;
alter table public.payment_methods enable row level security;
alter table public.dispensers      enable row level security;
alter table public.nozzles         enable row level security;

-- "An active user": the session's application user exists and is ACTIVE
-- (access rule, user model section 4). Policies read public.users directly,
-- which a signed-in person may do for their own row only.
create policy stations_select_active on public.stations for select to authenticated
  using (exists (select 1 from public.users u where u.auth_user_id = (select auth.uid()) and u.status = 'ACTIVE'));
create policy units_select_active on public.units for select to authenticated
  using (exists (select 1 from public.users u where u.auth_user_id = (select auth.uid()) and u.status = 'ACTIVE'));
create policy departments_select_active on public.departments for select to authenticated
  using (exists (select 1 from public.users u where u.auth_user_id = (select auth.uid()) and u.status = 'ACTIVE'));
create policy products_select_active on public.products for select to authenticated
  using (exists (select 1 from public.users u where u.auth_user_id = (select auth.uid()) and u.status = 'ACTIVE'));
create policy product_prices_select_active on public.product_prices for select to authenticated
  using (exists (select 1 from public.users u where u.auth_user_id = (select auth.uid()) and u.status = 'ACTIVE'));
create policy payment_methods_select_active on public.payment_methods for select to authenticated
  using (exists (select 1 from public.users u where u.auth_user_id = (select auth.uid()) and u.status = 'ACTIVE'));
create policy dispensers_select_active on public.dispensers for select to authenticated
  using (exists (select 1 from public.users u where u.auth_user_id = (select auth.uid()) and u.status = 'ACTIVE'));
create policy nozzles_select_active on public.nozzles for select to authenticated
  using (exists (select 1 from public.users u where u.auth_user_id = (select auth.uid()) and u.status = 'ACTIVE'));

-- A user sees their own station assignments; an administrator sees all.
create policy user_stations_select_own_or_admin on public.user_stations for select to authenticated
  using (exists (
    select 1 from public.users u
     where u.auth_user_id = (select auth.uid()) and u.status = 'ACTIVE'
       and (u.id = user_stations.user_id or u.role = 'ADMINISTRATOR')
  ));

-- ---------------------------------------------------------------------------
-- Reference data (the same on every database)
-- ---------------------------------------------------------------------------

insert into public.units (code, name) values
  ('L',  'Litre'),
  ('EA', 'Each');

insert into public.departments (code, name) values
  ('FUEL',  'Fuel'),
  ('LUBES', 'Lubricants');

insert into public.products (code, name, department_id, unit_code, kind)
select p.code, p.name, d.id, 'L', 'fuel'
  from (values ('PMS', 'Petrol (PMS)'), ('AGO', 'Diesel (AGO)'), ('VPOWER', 'Shell V-Power')) as p (code, name)
  cross join public.departments d
 where d.code = 'FUEL';

insert into public.payment_methods (code, name, type) values
  ('cash',         'Cash',         'cash'),
  ('shell_card',   'Shell Card',   'fleet_card'),
  ('stanbic_card', 'Stanbic card', 'card'),
  ('uba_card',     'UBA card',     'card'),
  ('absa_card',    'Absa card',    'card'),
  ('mtn_momo',     'MTN MoMo',     'mobile_money'),
  ('airtel_money', 'Airtel Money', 'mobile_money');
