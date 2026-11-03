# Fuel App

Fuel log for Maile Concrete. Drivers use a shop tablet to log truck, equipment and can fill-ups (gallons, DEF, odometer or hours), and the yard logs bulk tank loads, with receipt scanning to fill in the numbers.

## What's in here

| File | What it is |
| --- | --- |
| `index.html` | The whole app in one file. Open it in a browser on the tablet. |
| `supabase/setup.sql` | Database setup: tables, security rules and the PIN-checked functions the app calls. |
| `supabase/rename.sql` | Just the rename functions (also included in `setup.sql`), for adding renaming to a database that's already set up. |
| `supabase/functions/scan-receipt/index.ts` | Edge Function that reads a receipt photo with Gemini and returns vendor, address, date, time, line items and total. |
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
- Reports, deleting entries, managing the truck and driver lists, and the one-time import all go through database functions that check the 4-digit Reports PIN. The PIN is stored as a bcrypt hash, never in plain text.

## Conventions

- Fuel types: Unleaded is saved as **Gas**; everything else is **Diesel**.
- Asset barcodes look like `MC-NAME` (the name in capitals with spaces and symbols removed, e.g. `MC-TRUCK12`).
