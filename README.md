# Fuel App

Fuel log for Maile Concrete. Drivers use a shop tablet to log truck, equipment and can fill-ups (gallons, DEF, odometer or hours), and the yard logs bulk tank loads, with receipt scanning to fill in the numbers.

## What's in here

| File | What it is |
| --- | --- |
| `index.html` | The whole app in one file. Open it in a browser on the tablet. |
| `supabase/setup.sql` | Database setup: tables, security rules and the PIN-checked functions the app calls. |
| `supabase/maintenance.sql` | Just the maintenance and documents tables and functions (also included in `setup.sql`). |
| `supabase/fleet-details.sql` | One-time fill-in of the plates, VINs, expiry dates and odometers already known from the DMV papers, and puts every current vehicle under MAILE CONCRETE FLEET LLC. |
| `supabase/rename.sql` | Just the rename functions (also included in `setup.sql`), for adding renaming to a database that's already set up. |
| `supabase/functions/scan-receipt/index.ts` | Edge Function that reads a receipt photo with Gemini and returns vendor, address, date, time, line items and total. |
| `supabase/functions/vehicle-docs/index.ts` | Edge Function that uploads, opens and deletes a truck's documents after checking the Reports PIN. |
| `supabase/functions/scan-registration/index.ts` | Edge Function that reads a vehicle registration photo with Gemini and returns plate, state, VIN, year, make, model, owner and expiry. |

## 1. Set up the database

1. Open your project at [supabase.com](https://supabase.com/dashboard).
2. Go to **SQL Editor** > **New query**.
3. Paste the whole of `supabase/setup.sql` and click **Run**.

It is safe to run again at any time; it only creates what is missing and replaces the functions with the current version. Your data is not touched.

**Renaming trucks, equipment and drivers:** if your database was set up before renaming existed, paste `supabase/rename.sql` into a new query and click **Run** once. Then in Office, tap the pencil on a truck card (Trucks tab) or on any chip under **Manage**. A truck keeps its barcode when renamed, so printed labels keep scanning, and past fill-ups move to the new name.

The default Reports PIN is **1234**. Change it inside the app the first time you open Reports.

## 2. Deploy the receipt scanner

1. In Supabase, go to **Edge Functions** > **Deploy a new function** > **Via editor**.
2. Name it exactly `scan-receipt`.
3. Paste the whole of `supabase/functions/scan-receipt/index.ts` and click **Deploy**.
4. Get a Gemini API key from [aistudio.google.com](https://aistudio.google.com/apikey).
5. Go to **Edge Functions** > **Secrets**, add a secret named `GEMINI_API_KEY`, and paste the key as its value.

To update the scanner later, open the function, paste the new file over the old code, and deploy again. The secret stays.

The function tries several Gemini models in order (the `MODELS` list at the top of the file) and falls back to the next one if a model is missing or busy.

## 3. Deploy the registration scanner

1. In Supabase, go to **Edge Functions** > **Deploy a new function** > **Via editor**.
2. Name it exactly `scan-registration`.
3. Paste the whole of `supabase/functions/scan-registration/index.ts` and click **Deploy**.

It uses the same `GEMINI_API_KEY` secret as the receipt scanner, so there is nothing else to set.

## 4. Point the app at your project

Near the top of the script in `index.html` are `SUPABASE_URL` and `SUPABASE_ANON_KEY`. They must match **Project Settings** > **API** in Supabase. The anon key is meant to be public; the database rules below are what keep the logs safe.

## 5. Turn on maintenance and documents

1. In Supabase, go to **SQL Editor** > **New query**, paste the whole of `supabase/setup.sql` (or just `supabase/maintenance.sql`) and click **Run**. This adds the maintenance tables and a private file bucket called `vehicle-docs`.
2. Go to **Edge Functions** > **Deploy a new function** > **Via editor**, name it exactly `vehicle-docs`, paste the whole of `supabase/functions/vehicle-docs/index.ts` and click **Deploy**. There is no secret to add.

Then in Office > **Trucks**, tap any truck or machine:

- **Next service** shows about how far it is until the next service. Tap **Set interval** to choose every so many miles, engine hours or months (whichever comes first).
- **+ Log service** records an oil change, tires, brakes or any repair, with the odometer (or hour meter), cost, shop, notes and an optional receipt photo. Tap a past service to edit or delete it. The countdown starts from the most recent one, so log the last service first.
- **Registered / titled to** picks which company (LLC) the truck or machine is registered to. Pick **Other company...** to add a new one. Office > Trucks search finds trucks by company too.
- **+ Upload** adds a registration, receipt, insurance card or other paper as a photo or PDF. Tap one to open it.

### Editing a truck's details and photo

Each truck or machine page has a **Vehicle details** card at the top.

- **Change photo** (or tap the photo itself) takes or picks a new picture. It replaces the old one on the truck page and on the Office > Trucks cards. **Remove photo** goes back to the built-in one.
- **Edit details** changes the name, usual driver, fuel, DEF, VIN (serial number for equipment), plate (unit number for equipment), year, make, model, fuel tank size, the odometer (hour meter for equipment) right now and the day it was read, registration expiry and notes. The barcode never changes.
- An odometer typed in here counts for the service estimate and the Last odometer box when it's newer than what drivers entered on a fill-up.

To turn it on: run the latest `supabase/setup.sql`, and paste the latest `supabase/functions/vehicle-docs/index.ts` over the `vehicle-docs` function and deploy (photos are saved as a new "Photo" type). Then run `supabase/fleet-details.sql` once to fill in what's already known and set every vehicle to MAILE CONCRETE FLEET LLC.

How miles are estimated: when drivers enter the odometer it uses that. Fill-ups logged without an odometer each count as one full tank, which is **300 miles** for the Fords and the Ram unless you set a different number under **Set interval**.

Files are kept in a private bucket. The tablet's public key can't list or open them; the app only gets links (good for one hour) after the PIN is checked.

## Scanning registrations and making QR codes

1. Open **Reports**, enter the PIN, tap **Manage**, then **Scan registration**.
2. Tap **Photograph Registration** and take a photo of the registration card. The plate, VIN, year, make, model, owner and expiry fill in.
3. Under **Which truck is this?** pick the truck it belongs to, or leave it on **New truck or equipment** and type a name like `Truck 12`. If the VIN or unit number is already known, it is picked for you.
4. Check the details (the VIN gets a check-digit test, so a misread character is flagged) and tap **Save & Make QR Code**.
5. Tap **Print this label** to print that one label, or use **Print labels** in Manage to print all of them.

New trucks get an `MC-NAME` barcode. Re-scanning a truck that already has a barcode keeps the same one, so labels already on trucks keep working. The list at the bottom shows every registration on file and marks ones that are expired or expire within 30 days.

## How security works

- The tablet uses the anon key, which can only read active trucks, equipment and drivers, and add new fill-ups and tank loads.
- Registrations (plates, VINs, owner names) are only readable with the PIN; the tablet's public key cannot see them.
- Maintenance history, service intervals, uploaded documents and photos, and the details on each truck page (VIN, plate, tank size, odometer) are only readable and editable with the PIN too.
- Reports, deleting entries, managing the truck and driver lists, and the one-time import all go through database functions that check the 4-digit Reports PIN. The PIN is stored as a bcrypt hash, never in plain text.

## Conventions

- Fuel types: Unleaded is saved as **Gas**; everything else is **Diesel**.
- Asset barcodes look like `MC-NAME` (the name in capitals with spaces and symbols removed, e.g. `MC-TRUCK12`).
