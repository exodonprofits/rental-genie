-- rg_11: database advisor tidy-ups (pre-launch audit P2 2.6). No change to who can see what.
--
-- 1. RLS policies called auth.uid() / auth.email() / auth.jwt() directly, which Postgres
--    re-evaluates for every row. Wrapped as (select auth.uid()) etc. they run once per query.
--    The expressions are otherwise identical; this block rewrites the 28 flagged policies from
--    their live definitions and skips any that are already wrapped.
-- 2. Covering indexes for the 12 foreign-key columns the advisor flagged.
-- 3. Trigger-only functions lose EXECUTE for the API roles: triggers keep firing (Postgres doesn't
--    check EXECUTE when a trigger runs), but they can no longer be called through /rest/v1/rpc.
--
-- Not included: dropping the duplicate indexes idx_applications_property, idx_mr_property_id and
-- ux_properties_owner_name (each has an identical twin), to be run separately.

do $$
declare
  r record;
  q text;
  c text;
begin
  for r in
    select tablename, policyname, qual, with_check
    from pg_policies
    where schemaname = 'public'
      and (coalesce(qual, '') || coalesce(with_check, '')) ~ 'auth\.(uid|email|jwt)\(\)'
  loop
    q := r.qual;
    c := r.with_check;
    if q is not null and q !~* 'select auth\.' then
      q := replace(replace(replace(q, 'auth.uid()', '(select auth.uid())'),
                   'auth.email()', '(select auth.email())'), 'auth.jwt()', '(select auth.jwt())');
      execute format('alter policy %I on public.%I using (%s)', r.policyname, r.tablename, q);
    end if;
    if c is not null and c !~* 'select auth\.' then
      c := replace(replace(replace(c, 'auth.uid()', '(select auth.uid())'),
                   'auth.email()', '(select auth.email())'), 'auth.jwt()', '(select auth.jwt())');
      execute format('alter policy %I on public.%I with check (%s)', r.policyname, r.tablename, c);
    end if;
  end loop;
end $$;

create index if not exists idx_companies_owner_user_id            on public.companies (owner_user_id);
create index if not exists idx_company_members_user_id            on public.company_members (user_id);
create index if not exists idx_incoming_rent_payments_property_id on public.incoming_rent_payments (property_id);
create index if not exists idx_leases_created_by                  on public.leases (created_by);
create index if not exists idx_properties_user_id                 on public.properties (user_id);
create index if not exists idx_receipts_user_id                   on public.receipts (user_id);
create index if not exists idx_reimbursement_requests_expense_id  on public.reimbursement_requests (expense_id);
create index if not exists idx_tenant_documents_property_id       on public.tenant_documents (property_id);
create index if not exists idx_tenant_documents_tenant_id         on public.tenant_documents (tenant_id);
create index if not exists idx_tenant_messages_property_id        on public.tenant_messages (property_id);
create index if not exists idx_tenant_messages_tenant_id          on public.tenant_messages (tenant_id);
create index if not exists idx_tenant_payer_aliases_property_id   on public.tenant_payer_aliases (property_id);

revoke execute on function public.rg_cascade_property_rename()         from public, anon, authenticated;
revoke execute on function public.rg_fill_property_id_by_company()     from public, anon, authenticated;
revoke execute on function public.rg_tenants_limit_self_update()       from public, anon, authenticated;
revoke execute on function public.trigger_maintenance_acknowledgment() from public, anon, authenticated;
