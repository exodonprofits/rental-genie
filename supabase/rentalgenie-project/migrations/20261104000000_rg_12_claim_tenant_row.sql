-- rg_12: link a tenant's login to their tenants row (pre-launch audit, tenant pages P1).
--
-- Every tenant page tried to self-heal the link with update({ auth_user_id }) from the browser,
-- but tenants_update_self only matches rows already linked to auth.uid(), so for an unlinked row
-- the update matched nothing and failed silently: unlinked tenants stayed unlinked and lived on
-- the email-match fallback (and couldn't save their phone number).
--
-- rg_claim_tenant_row() does the link server-side. It links only when:
--   - the caller's login email is confirmed (a magic-link sign-in confirms it), so an account
--     created with someone else's address can't claim their row;
--   - the caller isn't already linked to a tenants row;
--   - exactly one unlinked tenants row has that email (case-insensitive).
-- It returns the caller's tenants.id (already linked or just linked), or null.
--
-- Also links the existing unlinked rows that meet the same conditions.

create or replace function public.rg_claim_tenant_row()
returns uuid
language plpgsql
volatile
security definer
set search_path to 'public'
set row_security to 'off'
as $$
declare
  v_uid uuid := auth.uid();
  v_email text;
  v_id uuid;
begin
  if v_uid is null then
    return null;
  end if;

  select id into v_id from public.tenants where auth_user_id = v_uid limit 1;
  if v_id is not null then
    return v_id;
  end if;

  select lower(u.email) into v_email
  from auth.users u
  where u.id = v_uid and u.email_confirmed_at is not null;
  if v_email is null then
    return null;
  end if;

  if (select count(*) from public.tenants
      where auth_user_id is null and lower(email) = v_email) <> 1 then
    return null;
  end if;

  update public.tenants
     set auth_user_id = v_uid
   where auth_user_id is null and lower(email) = v_email
  returning id into v_id;

  return v_id;
end;
$$;

revoke execute on function public.rg_claim_tenant_row() from public, anon;
grant execute on function public.rg_claim_tenant_row() to authenticated;

-- Existing unlinked rows: same rules (confirmed login, login not linked elsewhere, one row per email)
update public.tenants t
   set auth_user_id = u.id
  from auth.users u
 where t.auth_user_id is null
   and t.email is not null
   and lower(u.email) = lower(t.email)
   and u.email_confirmed_at is not null
   and not exists (select 1 from public.tenants t2 where t2.auth_user_id = u.id)
   and (select count(*) from public.tenants t3
        where t3.auth_user_id is null and lower(t3.email) = lower(t.email)) = 1;
