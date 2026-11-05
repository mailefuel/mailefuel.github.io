-- ============================================================
--  MAILE CONCRETE FUEL LOG — FILL IN KNOWN TRUCK DETAILS + SET THE LLC
--  Run supabase/setup.sql first (it adds the tank size / odometer columns).
--  Then paste this whole file into Supabase > SQL Editor > New query > Run.
--
--  1) Fills in what we already have from the DMV papers scanned on 2026-10-20:
--     plate, full VIN, year / make / model, registration expiry and the
--     odometer written on the renewal forms. It only fills EMPTY fields, so
--     anything you already typed on a truck page is never overwritten.
--  2) Puts every current truck and machine under MAILE CONCRETE FLEET LLC.
--
--  Safe to run again. Running it again sets the LLC on every vehicle again,
--  so if you later move one truck to another company, don't re-run this file.
-- ============================================================

alter table public.registrations add column if not exists tank_gal numeric;
alter table public.registrations add column if not exists odometer numeric;
alter table public.registrations add column if not exists hours numeric;
alter table public.registrations add column if not exists reading_on date;
alter table public.registrations add column if not exists notes text not null default '';

-- ---------- 1) details we already have ----------
do $$
declare
  v record;
  v_id uuid;
begin
  for v in
    select * from (values
      -- barcode                  plate     vin                   year  make         model              expires             odometer  read on             where it came from
      ('MC-LUISF2509900',         '1336C5', '1FT8X2AT4SEC09900',  2025, 'Ford',      'F250 Super Duty', date '2027-02-28',  null::numeric, null::date,     'DMV registration card'),
      ('MC-BASSILIOF250C09107',   '1337C5', '1FT8X2AT8SEC09107',  2025, 'Ford',      'F250 Super Duty', date '2027-02-28',  null,     null,                'DMV registration card'),
      ('MC-MARKYF55014011',       '220ZTF', '1FDUF5GT0KEF14011',  2019, 'Ford',      'F550 Super Duty', date '2027-02-02',  null,     null,                'DMV registration card'),
      ('MC-F750WATERTRUCK04042',  '947L20', '1FDWF7DE7JDF04042',  2018, 'Ford',      'F750 Super Duty', date '2026-11-25',  null,     null,                'DMV registration card'),
      ('MC-PETEF55008G403',       '08G403', '1FDUF5GT2GED39882',  2016, 'Ford',      'F550 Super Duty', date '2026-10-26',  null,     null,                'DMV registration card'),
      -- renewal notices: these only show the last 4 of the VIN, and the expiry printed on them is the one being renewed, so it's left out
      ('MC-JAVIERF5504277',       '332ZNV', '4277',               2019, 'Ford',      'F550',            null::date,         57000,    date '2026-05-14',   'DMV renewal notice'),
      ('MC-BERNARDOF550',         '08C623', '5898',               2016, 'Ford',      'F550',            null,               114002,   date '2025-09-29',   'DMV renewal notice'),
      ('MC-MARVINFORD2022',       '026ZXJ', '4297',               2022, 'Ford',      'Super Duty FX4',  null,               176212,   date '2026-03-12',   'DMV renewal notice'),
      ('MC-RAM3500C2150',         '054V18', '0635',               2019, 'Dodge Ram', '3500',            null,               null,     null,                'DMV renewal notice')
    ) as t(code, plate, vin, year, make, model, expires, odometer, reading_on, source)
  loop
    select id into v_id from public.assets where code = v.code;
    if v_id is null then continue; end if;   -- that truck isn't in the list

    insert into public.registrations (asset_id, plate, state, vin, year, make, model, expires, odometer, reading_on, updated_at)
    values (v_id, v.plate, 'NV', v.vin, v.year, v.make, v.model, v.expires, v.odometer, v.reading_on, now())
    on conflict (asset_id) do update set
      plate      = case when public.registrations.plate = '' then excluded.plate else public.registrations.plate end,
      state      = case when public.registrations.state = '' then excluded.state else public.registrations.state end,
      -- a full 17-character VIN replaces a blank or a last-4, never the other way round
      vin        = case when public.registrations.vin = ''
                          or (length(public.registrations.vin) < 17 and length(excluded.vin) = 17)
                        then excluded.vin else public.registrations.vin end,
      year       = coalesce(public.registrations.year, excluded.year),
      make       = case when public.registrations.make = '' then excluded.make else public.registrations.make end,
      model      = case when public.registrations.model = '' then excluded.model else public.registrations.model end,
      expires    = coalesce(public.registrations.expires, excluded.expires),
      odometer   = coalesce(public.registrations.odometer, excluded.odometer),
      reading_on = case when public.registrations.odometer is null then excluded.reading_on else public.registrations.reading_on end,
      updated_at = now();

    if v.odometer is not null then
      update public.registrations
         set notes = trim(both ' ' from notes || case when notes = '' then '' else ' ' end
                     || 'Odometer ' || to_char(v.odometer, 'FM999,999') || ' was written on the DMV renewal notice.')
       where asset_id = v_id and notes not like '%renewal notice%';
    end if;
  end loop;
end $$;

-- ---------- 2) every current vehicle is registered / titled to MAILE CONCRETE FLEET LLC ----------
insert into public.registrations (asset_id, owner, updated_at)
select a.id, 'MAILE CONCRETE FLEET LLC', now()
  from public.assets a
 where a.active
on conflict (asset_id) do update set owner = excluded.owner, updated_at = now();

-- Check: every vehicle and what's on file now
select a.kind, a.name, a.code, r.owner, r.plate, r.vin, r.year, r.make, r.model, r.expires, r.tank_gal, r.odometer, r.reading_on
  from public.assets a left join public.registrations r on r.asset_id = a.id
 where a.active
 order by a.kind desc, a.name;
