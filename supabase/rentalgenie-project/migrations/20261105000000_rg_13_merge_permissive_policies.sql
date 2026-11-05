-- rg_13: one permissive policy per table and command (pre-launch audit 2.6, advisor
-- multiple_permissive_policies: 34 findings on 13 tables).
--
-- Postgres evaluates every permissive policy that applies to a role and command and ORs them.
-- These tables had a landlord policy (company member, and on some also "owns the property" or
-- "created the lease"), a tenant or applicant policy, and often an ALL policy overlapping the
-- per-command ones. Each table now has one policy per command whose expression is exactly the
-- OR of the policies it replaces, so access is unchanged.
--
-- One tightening: the tenant-self policies (and tenant_messages' member policy, payment_settings'
-- member policy, tenants_update_self) were granted TO public, i.e. anon as well. Anonymous callers
-- can never satisfy them (no auth.uid(), no email), so the merged policies are TO authenticated.
--
-- Unchanged: restrictive policies (expenses_no_hard_delete), and every policy on these tables that
-- doesn't overlap (applications insert/update, companies insert). properties_no_delete was a
-- PERMISSIVE "using (false)", which grants nothing and blocks nothing, so it goes; property delete
-- behaviour is exactly as before (owner or company member).

-- ── application_messages ─────────────────────────────────────────────────────────────────
drop policy "applicant read messages" on public.application_messages;
drop policy "landlord read messages" on public.application_messages;
drop policy "applicant send messages" on public.application_messages;
drop policy "landlord send messages" on public.application_messages;

create policy application_messages_select on public.application_messages
  for select to authenticated
  using (
    (application_id in (select a.id from public.applications a
                         where a.applicant_user_id = (select auth.uid())))
    or (application_id in (select a.id from public.applications a
                             join public.properties p on p.id = a.property_id
                            where p.owner_id = (select auth.uid())))
  );

create policy application_messages_insert on public.application_messages
  for insert to authenticated
  with check (
    ((sender_role = 'applicant') and application_id in (select a.id from public.applications a
                                                          where a.applicant_user_id = (select auth.uid())))
    or ((sender_role = 'landlord') and application_id in (select a.id from public.applications a
                                                            join public.properties p on p.id = a.property_id
                                                           where p.owner_id = (select auth.uid())))
  );

-- ── applications (SELECT only) ───────────────────────────────────────────────────────────
drop policy "applicant view own applications" on public.applications;
drop policy "landlords manage their applications" on public.applications;

create policy applications_select on public.applications
  for select to authenticated
  using (
    (applicant_user_id = (select auth.uid()))
    or (property_id in (select p.id from public.properties p where p.owner_id = (select auth.uid())))
  );

-- ── companies (SELECT only) ──────────────────────────────────────────────────────────────
drop policy companies_select_member on public.companies;
drop policy companies_select_owner on public.companies;

create policy companies_select on public.companies
  for select to authenticated
  using (
    (owner_user_id = (select auth.uid()))
    or exists (select 1 from public.company_members cm
                where cm.company_id = companies.id and cm.user_id = (select auth.uid()))
  );

-- ── expenses (expenses_no_hard_delete, RESTRICTIVE, stays) ───────────────────────────────
drop policy expenses_owner_select on public.expenses;
drop policy expenses_owner_write on public.expenses;
drop policy expenses_rw_company_member on public.expenses;

create policy expenses_access on public.expenses
  for all to authenticated
  using (
    is_company_member(company_id)
    or exists (select 1 from public.properties p
                where p.id = expenses.property_id and p.owner_id = (select auth.uid()))
  )
  with check (
    is_company_member(company_id)
    or exists (select 1 from public.properties p
                where p.id = expenses.property_id and p.owner_id = (select auth.uid()))
  );

-- ── leases ───────────────────────────────────────────────────────────────────────────────
drop policy leases_rw_company_member on public.leases;
drop policy leases_select_own on public.leases;
drop policy leases_select_tenant_self on public.leases;
drop policy leases_insert_own on public.leases;
drop policy leases_update_own on public.leases;
drop policy leases_delete_own on public.leases;

create policy leases_select on public.leases
  for select to authenticated
  using (
    is_company_member(company_id)
    or (created_by = (select auth.uid()))
    or (lower(tenant_email) = rg_auth_email())
    or (tenant_id = rg_tenant_id_for_auth_user())
  );

create policy leases_insert on public.leases
  for insert to authenticated
  with check (
    is_company_member(company_id)
    or ((created_by = (select auth.uid())) and rg_company_access(company_id))
  );

create policy leases_update on public.leases
  for update to authenticated
  using (
    is_company_member(company_id)
    or ((created_by = (select auth.uid())) and rg_company_access(company_id))
  )
  with check (
    is_company_member(company_id)
    or ((created_by = (select auth.uid())) and rg_company_access(company_id))
  );

create policy leases_delete on public.leases
  for delete to authenticated
  using (
    is_company_member(company_id)
    or ((created_by = (select auth.uid())) and rg_company_access(company_id))
  );

-- ── maintenance_requests ─────────────────────────────────────────────────────────────────
drop policy maintenance_requests_rw_company_member on public.maintenance_requests;
drop policy maintenance_requests_select_tenant_self on public.maintenance_requests;
drop policy maintenance_requests_insert_tenant_self on public.maintenance_requests;

create policy maintenance_requests_select on public.maintenance_requests
  for select to authenticated
  using (
    is_company_member(company_id)
    or (lower(tenant_email) = rg_auth_email())
    or (tenant_id = rg_tenant_id_for_auth_user())
  );

create policy maintenance_requests_insert on public.maintenance_requests
  for insert to authenticated
  with check (
    is_company_member(company_id)
    or ((lower(tenant_email) = rg_auth_email()) and rg_tenant_can_file(company_id, property_id, tenant_id))
  );

create policy maintenance_requests_update on public.maintenance_requests
  for update to authenticated
  using (is_company_member(company_id))
  with check (is_company_member(company_id));

create policy maintenance_requests_delete on public.maintenance_requests
  for delete to authenticated
  using (is_company_member(company_id));

-- ── payment_settings ─────────────────────────────────────────────────────────────────────
drop policy "company members manage their payment settings" on public.payment_settings;
drop policy payment_settings_read_team_or_tenant on public.payment_settings;

create policy payment_settings_select on public.payment_settings
  for select to authenticated
  using (
    exists (select 1 from public.company_members cm
             where cm.company_id = payment_settings.company_id and cm.user_id = (select auth.uid()))
    or rg_company_access(company_id)
    or rg_is_tenant_of_company(company_id)
  );

create policy payment_settings_insert on public.payment_settings
  for insert to authenticated
  with check (exists (select 1 from public.company_members cm
                       where cm.company_id = payment_settings.company_id and cm.user_id = (select auth.uid())));

create policy payment_settings_update on public.payment_settings
  for update to authenticated
  using (exists (select 1 from public.company_members cm
                  where cm.company_id = payment_settings.company_id and cm.user_id = (select auth.uid())))
  with check (exists (select 1 from public.company_members cm
                       where cm.company_id = payment_settings.company_id and cm.user_id = (select auth.uid())));

create policy payment_settings_delete on public.payment_settings
  for delete to authenticated
  using (exists (select 1 from public.company_members cm
                  where cm.company_id = payment_settings.company_id and cm.user_id = (select auth.uid())));

-- ── properties ───────────────────────────────────────────────────────────────────────────
drop policy properties_no_delete on public.properties;
drop policy properties_owner_select on public.properties;
drop policy properties_owner_write on public.properties;
drop policy properties_rw_company_member on public.properties;

create policy properties_access on public.properties
  for all to authenticated
  using ((owner_id = (select auth.uid())) or is_company_member(company_id))
  with check ((owner_id = (select auth.uid())) or is_company_member(company_id));

-- ── reimbursement_requests ───────────────────────────────────────────────────────────────
drop policy reimbursement_requests_rw_company_member on public.reimbursement_requests;
drop policy reimbursement_requests_select_tenant_self on public.reimbursement_requests;
drop policy reimbursement_requests_insert_tenant_self on public.reimbursement_requests;

create policy reimbursement_requests_select on public.reimbursement_requests
  for select to authenticated
  using (
    is_company_member(company_id)
    or (lower(tenant_email) = rg_auth_email())
    or (tenant_id = rg_tenant_id_for_auth_user())
  );

create policy reimbursement_requests_insert on public.reimbursement_requests
  for insert to authenticated
  with check (is_company_member(company_id) or (lower(tenant_email) = rg_auth_email()));

create policy reimbursement_requests_update on public.reimbursement_requests
  for update to authenticated
  using (is_company_member(company_id))
  with check (is_company_member(company_id));

create policy reimbursement_requests_delete on public.reimbursement_requests
  for delete to authenticated
  using (is_company_member(company_id));

-- ── rent_log ─────────────────────────────────────────────────────────────────────────────
drop policy rent_log_owner_select on public.rent_log;
drop policy rent_log_owner_write on public.rent_log;
drop policy rent_log_rw_company_member on public.rent_log;
drop policy rent_log_select_tenant_self on public.rent_log;

create policy rent_log_select on public.rent_log
  for select to authenticated
  using (
    is_company_member(company_id)
    or exists (select 1 from public.properties p
                where p.id = rent_log.property_id and p.owner_id = (select auth.uid()))
    or (lower(tenant_email) = rg_auth_email())
    or (tenant_id = rg_tenant_id_for_auth_user())
  );

create policy rent_log_insert on public.rent_log
  for insert to authenticated
  with check (
    is_company_member(company_id)
    or exists (select 1 from public.properties p
                where p.id = rent_log.property_id and p.owner_id = (select auth.uid()))
  );

create policy rent_log_update on public.rent_log
  for update to authenticated
  using (
    is_company_member(company_id)
    or exists (select 1 from public.properties p
                where p.id = rent_log.property_id and p.owner_id = (select auth.uid()))
  )
  with check (
    is_company_member(company_id)
    or exists (select 1 from public.properties p
                where p.id = rent_log.property_id and p.owner_id = (select auth.uid()))
  );

create policy rent_log_delete on public.rent_log
  for delete to authenticated
  using (
    is_company_member(company_id)
    or exists (select 1 from public.properties p
                where p.id = rent_log.property_id and p.owner_id = (select auth.uid()))
  );

-- ── tenant_documents ─────────────────────────────────────────────────────────────────────
drop policy tenant_documents_rw_company_member on public.tenant_documents;
drop policy tenant_documents_select_tenant_self on public.tenant_documents;

create policy tenant_documents_select on public.tenant_documents
  for select to authenticated
  using (
    is_company_member(company_id)
    or (lower(tenant_email) = rg_auth_email())
    or (tenant_id = rg_tenant_id_for_auth_user())
  );

create policy tenant_documents_insert on public.tenant_documents
  for insert to authenticated
  with check (is_company_member(company_id));

create policy tenant_documents_update on public.tenant_documents
  for update to authenticated
  using (is_company_member(company_id))
  with check (is_company_member(company_id));

create policy tenant_documents_delete on public.tenant_documents
  for delete to authenticated
  using (is_company_member(company_id));

-- ── tenant_messages ──────────────────────────────────────────────────────────────────────
drop policy tenant_messages_rw_company_member on public.tenant_messages;
drop policy tenant_messages_select_tenant_self on public.tenant_messages;
drop policy tenant_messages_insert_tenant_self on public.tenant_messages;

create policy tenant_messages_select on public.tenant_messages
  for select to authenticated
  using (
    is_company_member(company_id)
    or (lower(tenant_email) = rg_auth_email())
    or (tenant_id = rg_tenant_id_for_auth_user())
  );

create policy tenant_messages_insert on public.tenant_messages
  for insert to authenticated
  with check (
    is_company_member(company_id)
    or ((lower(tenant_email) = rg_auth_email()) and (sender = 'tenant')
        and rg_tenant_can_file(company_id, null::uuid, tenant_id))
  );

create policy tenant_messages_update on public.tenant_messages
  for update to authenticated
  using (is_company_member(company_id))
  with check (is_company_member(company_id));

create policy tenant_messages_delete on public.tenant_messages
  for delete to authenticated
  using (is_company_member(company_id));

-- ── tenants ──────────────────────────────────────────────────────────────────────────────
drop policy tenants_rw_company_member_via_leases on public.tenants;
drop policy tenants_select_self on public.tenants;
drop policy tenants_update_self on public.tenants;

create policy tenants_select on public.tenants
  for select to authenticated
  using (
    exists (select 1 from public.leases l
             where lower(l.tenant_email) = lower(tenants.email) and is_company_member(l.company_id))
    or (auth_user_id = (select auth.uid()))
    or ((auth_user_id is null)
        and lower(email) = lower(coalesce((select auth.email()), ((select auth.jwt()) ->> 'email'))))
  );

create policy tenants_insert on public.tenants
  for insert to authenticated
  with check (exists (select 1 from public.leases l
                       where lower(l.tenant_email) = lower(tenants.email) and is_company_member(l.company_id)));

create policy tenants_update on public.tenants
  for update to authenticated
  using (
    exists (select 1 from public.leases l
             where lower(l.tenant_email) = lower(tenants.email) and is_company_member(l.company_id))
    or (auth_user_id = (select auth.uid()))
  )
  with check (
    exists (select 1 from public.leases l
             where lower(l.tenant_email) = lower(tenants.email) and is_company_member(l.company_id))
    or (auth_user_id = (select auth.uid()))
  );

create policy tenants_delete on public.tenants
  for delete to authenticated
  using (exists (select 1 from public.leases l
                  where lower(l.tenant_email) = lower(tenants.email) and is_company_member(l.company_id)));
