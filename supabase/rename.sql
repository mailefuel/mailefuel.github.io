-- ============================================================
--  MAILE CONCRETE FUEL LOG — RENAME TRUCKS, EQUIPMENT & DRIVERS
--  Paste this whole file into Supabase > SQL Editor > New query > Run.
--  Safe to run again (it only replaces these two functions).
--  The same functions are also at the end of setup.sql.
-- ============================================================

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
