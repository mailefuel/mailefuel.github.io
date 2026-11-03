-- ============================================================
--  MAILE CONCRETE FUEL LOG — SUPABASE SETUP
--  Paste this whole file into Supabase > SQL Editor > New query > Run.
--  Safe to run again; it only creates what's missing.
--  Default Reports PIN is 1234 (change it inside the app).
-- ============================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------- tables ----------
create table if not exists public.assets (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  fuel_type text not null default 'Diesel',
  uses_def boolean not null default true,
  kind text not null default 'Truck',          -- Truck | Equipment
  code text not null unique,                   -- barcode text, e.g. MC-TRUCK12
  driver text not null default '',             -- usual driver
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.drivers (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.fillups (
  id text primary key,
  ts timestamptz not null,
  truck text not null,
  driver text not null default '',
  odometer numeric,
  fuel_type text not null default '',
  fuel_gal numeric not null default 0,
  def_gal numeric not null default 0,
  kind text not null default 'Truck',          -- Truck | Equipment | Cans
  hours numeric,
  logged_by text not null default '',
  notes text not null default '',
  created_at timestamptz not null default now()
);
create index if not exists fillups_truck_ts on public.fillups (truck, ts desc);

create table if not exists public.tank_loads (
  id text primary key,
  ts timestamptz not null,
  product text not null,                       -- Diesel | Gas | DEF
  gallons numeric not null default 0,
  cost numeric not null default 0,
  price_per_gal numeric not null default 0,
  vendor text not null default '',
  address text not null default '',
  logged_by text not null default '',
  receipt_date text not null default '',
  receipt_time text not null default '',
  created_at timestamptz not null default now()
);

create table if not exists public.settings (
  key text primary key,
  value text not null
);
insert into public.settings (key, value)
  values ('pin_hash', extensions.crypt('1234', extensions.gen_salt('bf')))
  on conflict (key) do nothing;

-- ---------- row security ----------
alter table public.assets     enable row level security;
alter table public.drivers    enable row level security;
alter table public.fillups    enable row level security;
alter table public.tank_loads enable row level security;
alter table public.settings   enable row level security;

drop policy if exists "anon reads active assets"  on public.assets;
drop policy if exists "anon reads active drivers" on public.drivers;
drop policy if exists "anon logs fillups"         on public.fillups;
drop policy if exists "anon logs tank loads"      on public.tank_loads;

create policy "anon reads active assets"  on public.assets     for select to anon using (active);
create policy "anon reads active drivers" on public.drivers    for select to anon using (active);
create policy "anon logs fillups"         on public.fillups    for insert to anon with check (true);
create policy "anon logs tank loads"      on public.tank_loads for insert to anon with check (true);
-- Reading the logs, deleting, managing lists: only through the PIN-checked functions below.

-- ---------- helpers ----------
create or replace function public.pin_ok(p_pin text)
returns boolean language sql security definer stable set search_path = public as $$
  select exists (select 1 from public.settings where key = 'pin_hash' and value = extensions.crypt(coalesce(p_pin, ''), value));
$$;

create or replace function public.make_code(p_name text)
returns text language sql immutable as $$
  select 'MC-' || regexp_replace(upper(coalesce(p_name, '')), '[^A-Z0-9]', '', 'g');
$$;

-- ---------- functions the app calls ----------
create or replace function public.check_pin(p_pin text)
returns boolean language sql security definer stable set search_path = public as $$
  select public.pin_ok(p_pin);
$$;

create or replace function public.change_pin(p_old text, p_new text)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if not public.pin_ok(p_old) then raise exception 'wrong pin'; end if;
  if p_new !~ '^[0-9]{4}$' then raise exception 'pin must be 4 digits'; end if;
  update public.settings set value = extensions.crypt(p_new, extensions.gen_salt('bf')) where key = 'pin_hash';
  return true;
end $$;

-- For the tablet: last odometer / last driver per truck, nothing else
create or replace function public.latest_by_truck()
returns table (truck text, driver text, ts timestamptz, odometer numeric, odo_ts timestamptz)
language sql security definer stable set search_path = public as $$
  select f.truck, f.driver, f.ts, o.odometer, o.ts as odo_ts
  from (select distinct on (truck) truck, driver, ts from public.fillups where kind <> 'Cans' order by truck, ts desc) f
  left join (select distinct on (truck) truck, odometer, ts from public.fillups where kind <> 'Cans' and odometer > 0 order by truck, ts desc) o
    on o.truck = f.truck;
$$;

-- For Reports (PIN required): everything
create or replace function public.report_data(p_pin text)
returns json language plpgsql security definer stable set search_path = public as $$
begin
  if not public.pin_ok(p_pin) then raise exception 'wrong pin'; end if;
  return json_build_object(
    'fillups', (select coalesce(json_agg(row_to_json(f) order by f.ts desc), '[]'::json) from public.fillups f),
    'loads',   (select coalesce(json_agg(row_to_json(l) order by l.ts desc), '[]'::json) from public.tank_loads l)
  );
end $$;

create or replace function public.admin_delete(p_pin text, p_kind text, p_id text)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if not public.pin_ok(p_pin) then raise exception 'wrong pin'; end if;
  if p_kind = 'load' then delete from public.tank_loads where id = p_id;
  else delete from public.fillups where id = p_id; end if;
  return true;
end $$;

create or replace function public.admin_save_asset(p_pin text, p_name text, p_fuel text, p_def boolean, p_kind text, p_driver text, p_code text)
returns boolean language plpgsql security definer set search_path = public as $$
declare v_code text;
begin
  if not public.pin_ok(p_pin) then raise exception 'wrong pin'; end if;
  v_code := nullif(trim(coalesce(p_code, '')), '');
  if v_code is null then v_code := public.make_code(p_name); end if;
  insert into public.assets (name, fuel_type, uses_def, kind, code, driver, active)
  values (trim(p_name), case when p_fuel in ('Gas', 'Unleaded') then 'Gas' else 'Diesel' end, coalesce(p_def, true),
          case when p_kind = 'Equipment' then 'Equipment' else 'Truck' end, v_code, coalesce(trim(p_driver), ''), true)
  on conflict (name) do update set
    fuel_type = excluded.fuel_type, uses_def = excluded.uses_def, kind = excluded.kind,
    code = excluded.code, driver = excluded.driver, active = true;
  return true;
end $$;

create or replace function public.admin_remove_asset(p_pin text, p_name text)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if not public.pin_ok(p_pin) then raise exception 'wrong pin'; end if;
  update public.assets set active = false where name = trim(p_name);
  return true;
end $$;

create or replace function public.admin_add_driver(p_pin text, p_name text)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if not public.pin_ok(p_pin) then raise exception 'wrong pin'; end if;
  insert into public.drivers (name, active) values (trim(p_name), true)
  on conflict (name) do update set active = true;
  return true;
end $$;

create or replace function public.admin_remove_driver(p_pin text, p_name text)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if not public.pin_ok(p_pin) then raise exception 'wrong pin'; end if;
  update public.drivers set active = false where name = trim(p_name);
  return true;
end $$;

-- One-time import of the old Google Sheet data (the app sends the old script's JSON)
create or replace function public.admin_import(p_pin text, p_data json)
returns json language plpgsql security definer set search_path = public as $$
declare r json; n_f int := 0; n_l int := 0; n_a int := 0; n_d int := 0;
begin
  if not public.pin_ok(p_pin) then raise exception 'wrong pin'; end if;

  for r in select * from json_array_elements(coalesce(p_data->'drivers', '[]'::json)) loop
    insert into public.drivers (name, active) values (trim(r->>'name'), true) on conflict (name) do nothing;
    n_d := n_d + 1;
  end loop;

  for r in select * from json_array_elements(coalesce(p_data->'trucks', '[]'::json)) loop
    insert into public.assets (name, fuel_type, uses_def, kind, code, driver, active)
    values (trim(r->>'name'),
            case when (r->>'fuelType') in ('Gas', 'Unleaded') then 'Gas' else 'Diesel' end,
            coalesce((r->>'usesDef')::boolean, true),
            case when (r->>'kind') = 'Equipment' then 'Equipment' else 'Truck' end,
            coalesce(nullif(r->>'code', ''), public.make_code(r->>'name')),
            coalesce(r->>'driver', ''), true)
    on conflict (name) do nothing;
    n_a := n_a + 1;
  end loop;

  for r in select * from json_array_elements(coalesce(p_data->'fillups', '[]'::json)) loop
    insert into public.fillups (id, ts, truck, driver, odometer, fuel_type, fuel_gal, def_gal, kind, hours, logged_by, notes)
    values (r->>'id', (r->>'ts')::timestamptz, coalesce(r->>'truck', ''), coalesce(r->>'driver', ''),
            nullif(r->>'odometer', '')::numeric,
            case when (r->>'fuelType') = 'Unleaded' then 'Gas' else coalesce(r->>'fuelType', '') end,
            coalesce((r->>'fuelGal')::numeric, 0), coalesce((r->>'defGal')::numeric, 0),
            coalesce(nullif(r->>'kind', ''), 'Truck'), nullif(r->>'hours', '')::numeric,
            coalesce(r->>'by', ''), coalesce(r->>'notes', ''))
    on conflict (id) do nothing;
    n_f := n_f + 1;
  end loop;

  for r in select * from json_array_elements(coalesce(p_data->'loads', '[]'::json)) loop
    insert into public.tank_loads (id, ts, product, gallons, cost, price_per_gal, vendor, address, logged_by, receipt_date, receipt_time)
    values (r->>'id', (r->>'ts')::timestamptz,
            case when (r->>'product') = 'Unleaded' then 'Gas' else coalesce(r->>'product', 'Diesel') end,
            coalesce((r->>'gallons')::numeric, 0), coalesce((r->>'cost')::numeric, 0), coalesce((r->>'pricePerGal')::numeric, 0),
            coalesce(r->>'vendor', ''), coalesce(r->>'address', ''), coalesce(r->>'by', ''),
            coalesce(r->>'receiptDate', ''), coalesce(r->>'receiptTime', ''))
    on conflict (id) do nothing;
    n_l := n_l + 1;
  end loop;

  return json_build_object('fillups', n_f, 'loads', n_l, 'assets', n_a, 'drivers', n_d);
end $$;

-- ---------- vehicle registrations (scanned from the registration card) ----------
-- One row per truck / trailer / piece of equipment. No anon policy: plates, VINs and
-- owner names are only read and written through the PIN-checked functions below.
create table if not exists public.registrations (
  asset_id uuid primary key references public.assets(id) on delete cascade,
  plate text not null default '',
  state text not null default '',
  vin text not null default '',
  year int,
  make text not null default '',
  model text not null default '',
  owner text not null default '',
  expires date,
  updated_at timestamptz not null default now()
);
create index if not exists registrations_vin on public.registrations (vin);
alter table public.registrations enable row level security;

-- Save a scanned registration. Creates the truck if the name is new (with an MC-NAME barcode),
-- otherwise keeps its existing barcode so labels already printed keep working.
create or replace function public.admin_save_registration(
  p_pin text, p_name text, p_kind text, p_fuel text, p_def boolean,
  p_plate text, p_state text, p_vin text, p_year text, p_make text, p_model text, p_owner text, p_expires text)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_name text := trim(coalesce(p_name, ''));
  v_fuel text := case when p_fuel in ('Gas', 'Unleaded') then 'Gas' else 'Diesel' end;
  v_kind text := case when p_kind = 'Equipment' then 'Equipment' else 'Truck' end;
  v_id uuid; v_code text; v_base text; v_n int := 1; v_expires date; v_year int;
begin
  if not public.pin_ok(p_pin) then raise exception 'wrong pin'; end if;
  if v_name = '' then raise exception 'name required'; end if;

  if coalesce(p_year, '') ~ '^[0-9]{4}$' then v_year := p_year::int; end if;
  begin
    if coalesce(p_expires, '') ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then v_expires := p_expires::date; end if;
  exception when others then v_expires := null;
  end;

  select id, code into v_id, v_code from public.assets where name = v_name;
  if v_id is null then
    v_base := public.make_code(v_name);
    v_code := v_base;
    while exists (select 1 from public.assets where code = v_code) loop
      v_n := v_n + 1; v_code := v_base || '-' || v_n;
    end loop;
    insert into public.assets (name, fuel_type, uses_def, kind, code, driver, active)
    values (v_name, v_fuel, coalesce(p_def, true), v_kind, v_code, '', true)
    returning id into v_id;
  else
    update public.assets set fuel_type = v_fuel, uses_def = coalesce(p_def, true), kind = v_kind, active = true
    where id = v_id;
  end if;

  insert into public.registrations (asset_id, plate, state, vin, year, make, model, owner, expires, updated_at)
  values (v_id, upper(trim(coalesce(p_plate, ''))), upper(trim(coalesce(p_state, ''))), upper(trim(coalesce(p_vin, ''))),
          v_year, trim(coalesce(p_make, '')), trim(coalesce(p_model, '')), trim(coalesce(p_owner, '')), v_expires, now())
  on conflict (asset_id) do update set
    plate = excluded.plate, state = excluded.state, vin = excluded.vin, year = excluded.year, make = excluded.make,
    model = excluded.model, owner = excluded.owner, expires = excluded.expires, updated_at = now();

  return json_build_object('name', v_name, 'code', v_code);
end $$;

-- Every registration on file, with the truck's name and barcode (PIN required)
create or replace function public.admin_registrations(p_pin text)
returns json language plpgsql security definer stable set search_path = public as $$
begin
  if not public.pin_ok(p_pin) then raise exception 'wrong pin'; end if;
  return (
    select coalesce(json_agg(json_build_object(
      'name', a.name, 'code', a.code, 'kind', a.kind, 'active', a.active,
      'plate', r.plate, 'state', r.state, 'vin', r.vin, 'year', r.year, 'make', r.make, 'model', r.model,
      'owner', r.owner, 'expires', r.expires, 'updated_at', r.updated_at) order by a.name), '[]'::json)
    from public.registrations r join public.assets a on a.id = r.asset_id
  );
end $$;

-- ---------- renaming (Office > Manage, pencil button) ----------
-- Rename a truck or piece of equipment (PIN required).
-- Its barcode stays the same, so labels already on the trucks (and photos/<barcode>.jpg) keep working.
-- Past fill-ups logged under the old name move to the new name, so its history stays together.
create or replace function public.admin_rename_asset(p_pin text, p_old text, p_new text)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_old text := trim(coalesce(p_old, ''));
  v_new text := trim(coalesce(p_new, ''));
  v_id uuid; v_code text; v_key text;
begin
  if not public.pin_ok(p_pin) then raise exception 'wrong pin'; end if;
  if v_new = '' then raise exception 'new name required'; end if;
  select id, code into v_id, v_code from public.assets where name = v_old;
  if v_id is null then raise exception 'no truck named %', v_old; end if;
  if v_new = v_old then return json_build_object('name', v_new, 'code', v_code); end if;
  if exists (select 1 from public.assets where lower(name) = lower(v_new) and id <> v_id) then
    raise exception 'name taken: % is already in the list (or was removed earlier)', v_new;
  end if;

  update public.assets set name = v_new where id = v_id;
  -- fill-ups match on the name with spaces/dashes/case ignored, the same way the app matches them
  v_key := regexp_replace(upper(v_old), '[^A-Z0-9]', '', 'g');
  update public.fillups set truck = v_new
   where regexp_replace(upper(truck), '[^A-Z0-9]', '', 'g') = v_key;
  return json_build_object('name', v_new, 'code', v_code);
end $$;

-- Rename a driver (PIN required). Their past fill-ups and the trucks they usually drive follow the new name.
create or replace function public.admin_rename_driver(p_pin text, p_old text, p_new text)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_old text := trim(coalesce(p_old, ''));
  v_new text := trim(coalesce(p_new, ''));
  v_id uuid; v_key text;
begin
  if not public.pin_ok(p_pin) then raise exception 'wrong pin'; end if;
  if v_new = '' then raise exception 'new name required'; end if;
  select id into v_id from public.drivers where name = v_old;
  if v_id is null then raise exception 'no driver named %', v_old; end if;
  if v_new = v_old then return json_build_object('name', v_new); end if;
  if exists (select 1 from public.drivers where lower(name) = lower(v_new) and id <> v_id) then
    raise exception 'name taken: % is already in the list (or was removed earlier)', v_new;
  end if;

  update public.drivers set name = v_new where id = v_id;
  v_key := regexp_replace(upper(v_old), '[^A-Z0-9]', '', 'g');
  update public.fillups set driver = v_new where regexp_replace(upper(driver), '[^A-Z0-9]', '', 'g') = v_key;
  update public.fillups set logged_by = v_new where regexp_replace(upper(logged_by), '[^A-Z0-9]', '', 'g') = v_key;
  update public.assets set driver = v_new where regexp_replace(upper(driver), '[^A-Z0-9]', '', 'g') = v_key;
  return json_build_object('name', v_new);
end $$;
