-- Shared project: remove the old Rental Genie functions (step 2 of 2, after 20261110000000 dropped the tables)
--
-- Checked on 2026-11-18 before writing this:
--   - Every function below reads or writes the old Rental Genie tables (by name, public.*) or exists only to
--     serve them, so each one fails now if called. None is a trigger function still attached to a table.
--   - Their only callers are each other: no other function, view or cron job uses them, and two days of API
--     logs show no rpc calls to them.
--   - rg_company_access and rg_try_uuid back five Rental Genie storage policies on the receipts and
--     tenant-documents buckets. Those buckets are empty here; the policies grant access only to Rental
--     Genie's folder layout, so dropping them takes nothing from the other products' own policies.
--
-- Kept: rg_set_company_owner (BEFORE INSERT trigger on companies, which other products use: it fills
-- owner_user_id from auth.uid()) and is_company_member. The vault secret rg_maintenance_webhook_secret is
-- left alone; only its reader function goes.
--
-- No CASCADE: anything unexpected that still depends on one of these makes this fail and roll back.

set lock_timeout = '5s';

drop policy rg_receipts_landlord_insert on storage.objects;
drop policy rg_receipts_landlord_select on storage.objects;
drop policy rg_tenant_docs_insert       on storage.objects;
drop policy rg_tenant_docs_update       on storage.objects;
drop policy rg_tenant_docs_delete       on storage.objects;

drop function public.rg_rent_status(uuid, date);
drop function public.rg_rent_schedule(uuid, date);
drop function public.rg_confirm_incoming_payment(uuid, uuid, date, boolean);
drop function public.rg_dismiss_incoming_payment(uuid);
drop function public.rg_ingest_payment_email(text, text, text, text, text, numeric, date, text, text, text, text, boolean);
drop function public.rg_store_inbox_verification(text, text);
drop function public.rg_maintenance_webhook_secret();
drop function public.trigger_maintenance_acknowledgment();
drop function public.rg_cascade_property_rename();
drop function public.rg_fill_property_id_by_company();
drop function public.rg_fill_property_id_from_name();
drop function public.rg_sync_company_from_property();
drop function public.trg_sync_property_status_from_leases();
drop function public.rg_sync_property_status(uuid);
drop function public.sync_property_status(text);
drop function public.set_company_id_from_property();
drop function public.set_owner_and_property_ids();
drop function public.rg_tenants_limit_self_update();
drop function public.rg_tenant_can_file(uuid, uuid, uuid);
drop function public.rg_tenant_id_for_auth_user();
drop function public.rg_is_tenant_of_company(uuid);
drop function public.tenant_set_preferred_payment_method(uuid, text);
drop function public.claim_my_applications();
drop function public.auto_unpublish_listing();
drop function public.archive_expense(integer);
drop function public.unarchive_expense(integer);
drop function public.archive_lease(uuid);
drop function public.unarchive_lease(uuid);
drop function public.archive_maintenance_request(integer);
drop function public.unarchive_maintenance_request(integer);
drop function public.archive_property(uuid);
drop function public.unarchive_property(uuid);
drop function public.archive_rent_log(uuid);
drop function public.unarchive_rent_log(uuid);
drop function public.rg_can_access_property(uuid);
drop function public.rg_company_access(uuid);
drop function public.rg_try_uuid(text);
drop function public.rg_auth_email();
drop function public.rg_normalize_name(text);
