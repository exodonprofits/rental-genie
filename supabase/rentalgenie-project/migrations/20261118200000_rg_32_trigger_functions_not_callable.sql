-- rg_32: trigger functions aren't callable through the API.
--
-- Postgres grants EXECUTE on new functions to PUBLIC, so these were reachable as /rest/v1/rpc/<name> by anon and
-- signed-in users. Calling a trigger function directly only errors, but rg_lease_rent_changes_guard (rg_30) is
-- SECURITY DEFINER and the security advisor flags it. EXECUTE is checked when a trigger is created, not when it
-- fires, so the triggers keep working.
--
-- Tested 2026-11-18 in a rolled-back transaction as the landlord: a rent change still saves and gets company_id from
-- the guard, the guard still refuses a date before the lease start, a company insert carrying a Stripe account is
-- still refused (42501) and a plain one saves, a lease update runs the property-status sync, and a direct call of
-- the guard is refused (42501).

revoke execute on function
  public.rg_lease_rent_changes_guard(),
  public.auto_unpublish_listing(),
  public.block_tenant_email_change(),
  public.set_company_id_from_property(),
  public.set_owner_and_property_ids(),
  public.trg_sync_property_status_from_leases(),
  public.trigger_companies_protect_stripe()
from public, anon, authenticated;
