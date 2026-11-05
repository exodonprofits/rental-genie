-- rg_16: link an expense to the repair it paid for (Snap-it for maintenance invoices).
--
-- expenses.maintenance_request_id is set when an invoice is snapped from a repair on
-- maintenance-requests.html, and when a tenant reimbursement for a repair is approved. The repair
-- page shows the invoiced total from these rows.
--
-- The foreign key is composite, (maintenance_request_id, company_id) -> maintenance_requests
-- (id, company_id), so an expense can only point at a repair in its own company: a landlord can't
-- attach an expense to another company's repair id. Repairs are archived, not deleted, but if one
-- ever is deleted only the link is cleared (ON DELETE SET NULL on that one column).

create unique index if not exists ux_maintenance_requests_id_company
  on public.maintenance_requests (id, company_id);

alter table public.expenses
  add column if not exists maintenance_request_id integer;

alter table public.expenses
  add constraint expenses_maintenance_request_fkey
  foreign key (maintenance_request_id, company_id)
  references public.maintenance_requests (id, company_id)
  on delete set null (maintenance_request_id);

create index if not exists idx_expenses_maintenance_request_id
  on public.expenses (maintenance_request_id)
  where maintenance_request_id is not null;
