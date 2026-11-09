-- rg_24: (1) notification kinds become rows in a lookup table instead of a check constraint, so a new
-- kind is an insert, not a constraint replacement (each of which needed a confirmation in the
-- Supabase tools); (2) a vendor directory per company.

create table if not exists public.notification_kinds (
  kind        text primary key,
  description text not null
);
insert into public.notification_kinds (kind, description) values
  ('maintenance_ack',  'Tenant: we received your repair request'),
  ('landlord_repair',  'Landlord: a tenant filed a repair'),
  ('landlord_message', 'Landlord: a tenant sent a message'),
  ('rent_due',         'Landlord: rent due in 3 days'),
  ('rent_overdue',     'Landlord: rent past its grace period'),
  ('lease_expiry',     'Landlord: lease ending in 30 days'),
  ('monthly_summary',  'Landlord: monthly summary'),
  ('repair_update',    'Tenant: repair scheduled, assigned, in progress or completed')
on conflict (kind) do nothing;
alter table public.notification_kinds enable row level security;
revoke all on public.notification_kinds from anon, authenticated;

alter table public.notifications drop constraint notifications_kind_check;
alter table public.notifications add constraint notifications_kind_fkey
  foreign key (kind) references public.notification_kinds (kind);

-- Vendor directory: archived, never removed (no delete policy)
create table if not exists public.vendors (
  id          uuid primary key default gen_random_uuid(),
  company_id  uuid not null references public.companies (id),
  name        text not null check (length(btrim(name)) between 1 and 120),
  trade       text,
  phone       text,
  email       text,
  notes       text,
  archived_at timestamptz,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create unique index if not exists ux_vendors_company_name on public.vendors (company_id, lower(btrim(name)));
alter table public.vendors enable row level security;
revoke all on public.vendors from anon, authenticated;
grant select, insert, update on public.vendors to authenticated;
create policy vendors_select on public.vendors for select to authenticated using (public.rg_company_access(company_id));
create policy vendors_insert on public.vendors for insert to authenticated with check (public.rg_company_access(company_id));
create policy vendors_update on public.vendors for update to authenticated
  using (public.rg_company_access(company_id)) with check (public.rg_company_access(company_id));
