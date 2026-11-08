-- rg_19: a landlord can change a tenant's email; a tenant still can't change their own.
--
-- Before: trg_block_tenant_email_change refused every change to tenants.email, from anyone. The
-- tenant's My Account page says "your landlord will update it", but nobody could. Editing the
-- tenant email on a lease also left the tenants row behind with the old address, and since the
-- tenants policies match on lease.tenant_email = tenants.email, the row then fell out of the
-- landlord's view.
--
-- Now rg_update_tenant_email(lease, email), callable by anyone with access to the lease's company:
--   - updates tenant_email on that lease and on the tenant's other non-archived leases the caller
--     can access, and tenants.email, in one transaction;
--   - clears tenants.auth_user_id when the email actually changes, so the old login is unlinked and
--     the new address claims the row through rg_claim_tenant_row (confirmed email, single match);
--   - rejects an invalid address, and one another tenants row already uses (the claim needs exactly
--     one match).
-- The email trigger lets a change through only inside that function (a transaction-local setting
-- that clients can't set: set_config isn't exposed through the API). Direct updates stay blocked.

create or replace function public.block_tenant_email_change()
returns trigger
language plpgsql
set search_path = 'public'
as $$
begin
  if new.email is distinct from old.email
     and coalesce(current_setting('rg.tenant_email_change', true), '') <> 'allowed' then
    raise exception 'Tenant email cannot be changed.';
  end if;
  return new;
end;
$$;

-- The self-update guard limits a signed-in tenant to their phone; let the landlord function through
-- (it matters only when the landlord is also the tenant on the row).
create or replace function public.rg_tenants_limit_self_update()
returns trigger
language plpgsql
security definer
set search_path = 'public'
set row_security = off
as $$
begin
  if auth.uid() is null or old.auth_user_id is distinct from auth.uid() then
    return new;
  end if;
  if coalesce(current_setting('rg.tenant_email_change', true), '') = 'allowed' then
    return new;
  end if;
  if exists (select 1 from public.leases l
             where lower(l.tenant_email) = lower(old.email)
               and public.rg_company_access(l.company_id)) then
    return new;
  end if;
  if (to_jsonb(new) - 'phone') is distinct from (to_jsonb(old) - 'phone') then
    raise exception 'Tenants can only update their phone number.' using errcode = '42501';
  end if;
  return new;
end;
$$;

create or replace function public.rg_update_tenant_email(p_lease_id uuid, p_email text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_email     text := btrim(coalesce(p_email, ''));
  v_company   uuid;
  v_tenant    uuid;
  v_old_email text;
  v_old_auth  uuid;
begin
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'Enter a valid email address.' using errcode = '22023';
  end if;

  select l.company_id, l.tenant_id into v_company, v_tenant
    from public.leases l where l.id = p_lease_id;
  if v_company is null or not public.rg_company_access(v_company) then
    raise exception 'You can only change tenant emails on your own leases.' using errcode = '42501';
  end if;

  update public.leases set tenant_email = v_email
   where id = p_lease_id and tenant_email is distinct from v_email;

  if v_tenant is null then
    return jsonb_build_object('tenant_record', false, 'changed', false);
  end if;

  select t.email, t.auth_user_id into v_old_email, v_old_auth from public.tenants t where t.id = v_tenant;
  if lower(coalesce(v_old_email, '')) = lower(v_email) then
    return jsonb_build_object('tenant_record', true, 'changed', false);
  end if;

  if exists (select 1 from public.tenants t where lower(t.email) = lower(v_email) and t.id <> v_tenant) then
    raise exception 'Another tenant already uses that email address.' using errcode = '23505';
  end if;

  perform set_config('rg.tenant_email_change', 'allowed', true);
  update public.tenants set email = v_email, auth_user_id = null where id = v_tenant;
  update public.leases l set tenant_email = v_email
   where l.tenant_id = v_tenant and l.archived_at is null and l.id <> p_lease_id
     and l.tenant_email is distinct from v_email and public.rg_company_access(l.company_id);
  perform set_config('rg.tenant_email_change', '', true);

  return jsonb_build_object('tenant_record', true, 'changed', true, 'login_unlinked', v_old_auth is not null);
end;
$$;

revoke execute on function public.rg_update_tenant_email(uuid, text) from public, anon;
grant execute on function public.rg_update_tenant_email(uuid, text) to authenticated;
