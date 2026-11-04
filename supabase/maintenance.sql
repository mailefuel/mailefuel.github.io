-- ---------- maintenance + vehicle documents (Office > Trucks > tap a truck) ----------
-- Safe to run again. Nothing here is readable by the tablet's public (anon) key:
-- every table has row security on with no anon policy, and the documents bucket is private.
-- The app reads and writes all of it through the PIN-checked functions below and the
-- vehicle-docs Edge Function (which checks the PIN before touching a file).

-- How often each truck gets serviced, and how far it goes on a tank
create table if not exists public.service_plans (
  asset_id uuid primary key references public.assets(id) on delete cascade,
  every_miles int,                              -- e.g. 5000 (trucks)
  every_hours int,                              -- e.g. 250 (equipment)
  every_months int,                             -- e.g. 6 (whichever comes first)
  miles_per_tank numeric,                       -- e.g. 300 for the Fords and the Ram
  updated_at timestamptz not null default now()
);

-- Completed maintenance
create table if not exists public.maintenance (
  id uuid primary key default gen_random_uuid(),
  asset_id uuid not null references public.assets(id) on delete cascade,
  done_on date not null,
  odometer numeric,
  hours numeric,
  work text not null default '',               -- Oil change, Tires, Brakes, ...
  cost numeric,
  vendor text not null default '',
  notes text not null default '',
  logged_by text not null default '',
  created_at timestamptz not null default now()
);
create index if not exists maintenance_asset_done on public.maintenance (asset_id, done_on desc);

-- Uploaded documents (the file itself is in the private storage bucket "vehicle-docs")
create table if not exists public.vehicle_docs (
  id uuid primary key default gen_random_uuid(),
  asset_id uuid not null references public.assets(id) on delete cascade,
  doc_type text not null default 'Other',      -- Registration | Receipt | Insurance | Inspection | Title | Other
  title text not null default '',
  file_path text not null unique,
  mime text not null default '',
  size_bytes bigint not null default 0,
  maint_id uuid references public.maintenance(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists vehicle_docs_asset on public.vehicle_docs (asset_id, created_at desc);

alter table public.service_plans enable row level security;
alter table public.maintenance   enable row level security;
alter table public.vehicle_docs  enable row level security;

-- Private bucket for the files. No storage policies, so only the Edge Function (after the PIN check) can use it.
insert into storage.buckets (id, name, public)
values ('vehicle-docs', 'vehicle-docs', false)
on conflict (id) do update set public = false;

-- Service plan + last service for every truck (PIN required). Feeds the badges on Office > Trucks.
create or replace function public.admin_fleet_service(p_pin text)
returns json language plpgsql security definer stable set search_path = public as $$
begin
  if not public.pin_ok(p_pin) then raise exception 'wrong pin'; end if;
  return (
    select coalesce(json_agg(json_build_object(
      'code', a.code, 'name', a.name,
      'every_miles', p.every_miles, 'every_hours', p.every_hours, 'every_months', p.every_months,
      'miles_per_tank', p.miles_per_tank,
      'make', r.make, 'model', r.model, 'owner', coalesce(r.owner, ''),
      'last', (select row_to_json(m) from (
                 select m.id, m.done_on, m.odometer, m.hours, m.work from public.maintenance m
                 where m.asset_id = a.id order by m.done_on desc, m.created_at desc limit 1) m),
      'docs', (select count(*) from public.vehicle_docs d where d.asset_id = a.id)
    )), '[]'::json)
    from public.assets a
    left join public.service_plans p on p.asset_id = a.id
    left join public.registrations r on r.asset_id = a.id
    where a.active
  );
end $$;

-- Everything for one truck's page (PIN required): plan, maintenance history, documents, registration
create or replace function public.admin_vehicle_detail(p_pin text, p_code text)
returns json language plpgsql security definer stable set search_path = public as $$
declare v_id uuid;
begin
  if not public.pin_ok(p_pin) then raise exception 'wrong pin'; end if;
  select id into v_id from public.assets where code = p_code;
  if v_id is null then raise exception 'no truck with barcode %', p_code; end if;
  return json_build_object(
    'plan', (select row_to_json(p) from public.service_plans p where p.asset_id = v_id),
    'maintenance', (select coalesce(json_agg(row_to_json(m) order by m.done_on desc, m.created_at desc), '[]'::json)
                    from public.maintenance m where m.asset_id = v_id),
    'docs', (select coalesce(json_agg(json_build_object(
               'id', d.id, 'doc_type', d.doc_type, 'title', d.title, 'file_path', d.file_path, 'mime', d.mime,
               'size_bytes', d.size_bytes, 'maint_id', d.maint_id, 'created_at', d.created_at) order by d.created_at desc), '[]'::json)
             from public.vehicle_docs d where d.asset_id = v_id),
    'registration', (select json_build_object('plate', r.plate, 'state', r.state, 'vin', r.vin, 'year', r.year,
                       'make', r.make, 'model', r.model, 'expires', r.expires, 'owner', r.owner)
                     from public.registrations r where r.asset_id = v_id)
  );
end $$;

-- Set a truck's service interval (PIN required). Blank / 0 clears that part.
create or replace function public.admin_save_service_plan(p_pin text, p_code text, p_every_miles int, p_every_hours int, p_every_months int, p_miles_per_tank numeric)
returns boolean language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if not public.pin_ok(p_pin) then raise exception 'wrong pin'; end if;
  select id into v_id from public.assets where code = p_code;
  if v_id is null then raise exception 'no truck with barcode %', p_code; end if;
  insert into public.service_plans (asset_id, every_miles, every_hours, every_months, miles_per_tank, updated_at)
  values (v_id, nullif(p_every_miles, 0), nullif(p_every_hours, 0), nullif(p_every_months, 0), nullif(p_miles_per_tank, 0), now())
  on conflict (asset_id) do update set
    every_miles = excluded.every_miles, every_hours = excluded.every_hours, every_months = excluded.every_months,
    miles_per_tank = excluded.miles_per_tank, updated_at = now();
  return true;
end $$;

-- Log (or edit, when p_id is given) a completed service (PIN required). Returns its id.
create or replace function public.admin_save_maintenance(p_pin text, p_code text, p_id uuid, p_done_on date, p_odometer numeric, p_hours numeric,
                                                         p_work text, p_cost numeric, p_vendor text, p_notes text, p_by text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_mid uuid;
begin
  if not public.pin_ok(p_pin) then raise exception 'wrong pin'; end if;
  select id into v_id from public.assets where code = p_code;
  if v_id is null then raise exception 'no truck with barcode %', p_code; end if;
  if p_done_on is null then raise exception 'date required'; end if;
  if p_id is null then
    insert into public.maintenance (asset_id, done_on, odometer, hours, work, cost, vendor, notes, logged_by)
    values (v_id, p_done_on, nullif(p_odometer, 0), nullif(p_hours, 0), trim(coalesce(p_work, '')), nullif(p_cost, 0),
            trim(coalesce(p_vendor, '')), trim(coalesce(p_notes, '')), trim(coalesce(p_by, '')))
    returning id into v_mid;
  else
    update public.maintenance set done_on = p_done_on, odometer = nullif(p_odometer, 0), hours = nullif(p_hours, 0),
      work = trim(coalesce(p_work, '')), cost = nullif(p_cost, 0), vendor = trim(coalesce(p_vendor, '')),
      notes = trim(coalesce(p_notes, ''))
    where id = p_id and asset_id = v_id
    returning id into v_mid;
  end if;
  return v_mid;
end $$;

create or replace function public.admin_delete_maintenance(p_pin text, p_id uuid)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if not public.pin_ok(p_pin) then raise exception 'wrong pin'; end if;
  delete from public.maintenance where id = p_id;
  return true;
end $$;

-- Which company (LLC) a truck or machine is registered / titled to (PIN required).
-- Works for equipment with no registration card too: it starts an empty registration row.
create or replace function public.admin_set_owner(p_pin text, p_code text, p_owner text)
returns boolean language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if not public.pin_ok(p_pin) then raise exception 'wrong pin'; end if;
  select id into v_id from public.assets where code = p_code;
  if v_id is null then raise exception 'no truck with barcode %', p_code; end if;
  insert into public.registrations (asset_id, owner, updated_at) values (v_id, trim(coalesce(p_owner, '')), now())
  on conflict (asset_id) do update set owner = excluded.owner, updated_at = now();
  return true;
end $$;
