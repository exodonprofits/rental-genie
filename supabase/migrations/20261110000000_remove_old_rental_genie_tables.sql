-- Shared project: remove the old Rental Genie tables (step 1 of 2: views, policies, tables)
--
-- Rental Genie has run on its own project (xqmnaeujwumlcoyhgzuk) since Oct 1 2026. Its old tables here
-- were locked read-only on Oct 2 (20261002000000) and have sat unused since, still holding a stale copy
-- of tenants, leases and payments inside the database the other products use.
--
-- Checked on 2026-11-10 before writing this:
--   - Every row in the 20 copied tables exists in the RentalGenie project (id fingerprints match per
--     table), except 15 rent_log rows from Apr-Sep 2026 that the landlord deleted there and re-entered
--     on Oct 11 2026; each of those due dates is logged in the RentalGenie project.
--   - The 12 tables never moved (no page used them) hold 5 stale rows: 2 lease_rent_adjustments (one a
--     $1 test), 2 property_inbox_map rows, 1 expired property_insurance record.
--   - Nothing outside Rental Genie depends on them: no views other than the Rental Genie ones dropped
--     below, no triggers or cron jobs; the only foreign key from another table is
--     token_usage_log -> rental_tasks (both empty), dropped below. Three Rental Genie storage policies
--     read these tables; their buckets here (tenant-documents, maintenance-photos, receipts) are empty.
--
-- Kept: companies, company_members and receipts (the other products use them), and the Rental Genie
-- storage policies that don't read these tables. Functions go in step 2 (20261110000100), once the
-- triggers and policies that use them are gone with the tables.
--
-- No CASCADE anywhere: an unexpected dependency makes this fail and roll back instead of taking
-- something else with it. lock_timeout keeps the storage.objects policy change from queueing behind
-- uploads: it fails fast and can be re-run.

set lock_timeout = '5s';

do $$
declare c text;
begin
  for c in select conname from pg_constraint
           where conrelid = 'public.token_usage_log'::regclass and confrelid = 'public.rental_tasks'::regclass loop
    execute format('alter table public.token_usage_log drop constraint %I', c);
  end loop;
end $$;

drop policy rg_tenant_docs_select    on storage.objects;
drop policy rg_receipts_reimb_select on storage.objects;
drop policy rg_maint_photos_select   on storage.objects;

drop view public.public_listings;
drop view public.property_monthly_costs;
drop view public.active_rent_log;
drop view public.active_properties;
drop view public.active_maintenance_requests;
drop view public.active_leases;
drop view public.active_expenses;

-- Children before parents (foreign keys between these tables)
drop table public.property_escrow_ledger;
drop table public.escrow_transactions;
drop table public.lease_rent_adjustments;
drop table public.lease_status_log;
drop table public.rental_tasks;
drop table public.tenant_payer_aliases;
drop table public.incoming_rent_payments;
drop table public.application_messages;
drop table public.applications;
drop table public.reimbursement_requests;
drop table public.tenant_messages;
drop table public.tenant_documents;
drop table public.maintenance_requests;
drop table public.expenses;
drop table public.expense_recurring_rules;
drop table public.rent_log;
drop table public.tenant_invites;
drop table public.tenant_portal_users;
drop table public.leases;
drop table public.tenants;
drop table public.hoa_history;
drop table public.property_hoa;
drop table public.property_tax_history;
drop table public.property_insurance_history;
drop table public.property_insurance;
drop table public.property_finance_history;
drop table public.property_financing_history;
drop table public.property_mortgage_activity;
drop table public.property_inbox_map;
drop table public.payment_settings;
drop table public.pmc_staff;
drop table public.owners;
drop table public.properties;
