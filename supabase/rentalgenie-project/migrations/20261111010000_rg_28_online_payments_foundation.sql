-- rg_28: foundation for online rent payments (docs/design/stripe-online-rent.md, section 4). Nothing here
-- talks to Stripe; the Edge Functions that use it come next.
--
-- 1. rg_apply_payment(): the oldest-month-first split and prepayment logic, moved out of
--    rg_confirm_incoming_payment so the payment inbox and Stripe record payments the same way.
--    rg_confirm_incoming_payment now calls it. Same rows as before (checked in a rolled-back test on
--    2026-11-11 against the old function for partial, exact, multi-month, prepaid, ended-lease and
--    fixed-due-date payments), plus each rent_log row now carries the lease, tenant id and tenant email of
--    the lease in effect: before, inbox payments were saved without them, so tenants couldn't see those
--    payments in their history (no inbox payment had been confirmed yet, so nothing to backfill).
--    SECURITY INVOKER: a landlord's call is limited by rent_log's row-level security as before; the
--    Stripe webhook will call it with the service role.
--
-- 2. companies.stripe_*: the landlord's connected Stripe account and its state, written only by the
--    service role (Edge Functions / webhook). A trigger refuses changes from signed-in users, so a company
--    member can't point rent at another Stripe account.
--
-- 3. online_payments: one row per online payment attempt. Landlords (company access) and the paying
--    tenant can read; only the service role writes. rent_log.online_payment_id links recorded rent back.
--
-- 4. leases.pay_accepts_online (default on): the landlord can turn online payment off for one lease.
--
-- 5. Notification kinds for online payments.
--
-- 6. rg_tenant_id_for_auth_user() is no longer callable by anon (it returned nothing for anon anyway;
--    no anon policy uses it).

-- 1 ─────────────────────────────────────────────────────────────────────────────────────────────
alter table public.rent_log add column if not exists online_payment_id uuid;

create or replace function public.rg_apply_payment(
  p_company            uuid,
  p_property           uuid,
  p_amount             numeric,
  p_date_paid          date,
  p_method             text,
  p_note               text,
  p_source             text,
  p_due_date           date default null,   -- record the whole amount against this due date
  p_fallback_due       date default null,   -- first prepaid due date when the lease has no schedule
  p_incoming_payment   uuid default null,
  p_online_payment     uuid default null)
returns uuid[]
language plpgsql
set search_path = ''
as $$
declare
  v_asof     date := coalesce(p_date_paid, current_date);
  v_pname    text;
  v_lease    uuid;
  v_tname    text;
  v_tid      uuid;
  v_temail   text;
  v_left     numeric := p_amount;
  v_ids      uuid[] := '{}';
  v_new      uuid;
  r          record;
  v_last_due date;
  v_due_day  int;
  v_rent     numeric;
  v_next     date;
  v_chunk    numeric;
  v_i        int := 0;
begin
  if p_amount is null or p_amount <= 0 then
    raise exception 'The payment amount must be more than zero.' using errcode = '22023';
  end if;
  select p.name into v_pname from public.properties p where p.id = p_property and p.company_id = p_company;
  if v_pname is null then
    raise exception 'That property isn''t part of this company.' using errcode = '22023';
  end if;

  -- The lease in effect on the payment date, and its tenant
  select s.lease_id, s.tenant_name into v_lease, v_tname
    from public.rg_rent_status(p_company, v_asof) s where s.property_id = p_property;
  if v_lease is not null then
    select l.tenant_id, nullif(btrim(l.tenant_email), '') into v_tid, v_temail from public.leases l where l.id = v_lease;
  end if;

  if p_due_date is not null then
    insert into public.rent_log (company_id, property_id, property_name, lease_id, tenant_id, tenant_email, tenant_name,
                                 amount, date_paid, method, applied_to_due_date, note, source,
                                 incoming_payment_id, online_payment_id)
    values (p_company, p_property, v_pname, v_lease, v_tid, v_temail, v_tname,
            v_left, p_date_paid, p_method, p_due_date, p_note, p_source, p_incoming_payment, p_online_payment)
    returning id into v_new;
    return v_ids || v_new;
  end if;

  -- Unpaid months, oldest first
  for r in
    select s.due_date, s.balance
      from public.rg_rent_schedule(p_company, v_asof) s
     where s.property_id = p_property and s.balance > 0.01
     order by s.due_date
  loop
    exit when v_left <= 0.01;
    insert into public.rent_log (company_id, property_id, property_name, lease_id, tenant_id, tenant_email, tenant_name,
                                 amount, date_paid, method, applied_to_due_date, note, source,
                                 incoming_payment_id, online_payment_id)
    values (p_company, p_property, v_pname, v_lease, v_tid, v_temail, v_tname,
            least(v_left, r.balance), p_date_paid, p_method, r.due_date, p_note, p_source,
            p_incoming_payment, p_online_payment)
    returning id into v_new;
    v_ids := v_ids || v_new;
    v_left := v_left - least(v_left, r.balance);
  end loop;

  -- Anything left is a prepayment, in rent-sized pieces on the following due dates
  if v_left > 0.01 then
    select max(s.due_date), max(s.due_day), max(s.rent_amount)
      into v_last_due, v_due_day, v_rent
      from public.rg_rent_schedule(p_company, v_asof) s
     where s.property_id = p_property;

    v_next := v_last_due;
    while v_left > 0.01 loop
      v_i := v_i + 1;
      if v_next is null or v_due_day is null then
        v_next := coalesce(p_fallback_due, p_date_paid, current_date);
      else
        v_next := (date_trunc('month', v_next) + interval '1 month')::date
                  + (least(v_due_day,
                           extract(day from (date_trunc('month', v_next) + interval '2 month' - interval '1 day'))::int) - 1);
      end if;
      v_chunk := case when v_rent is null or v_rent <= 0 or v_i >= 24 then v_left else least(v_left, v_rent) end;
      if v_i > 1 and v_left < v_rent and v_left > 0.01 and v_ids <> '{}' then
        update public.rent_log set amount = amount + v_left where id = v_ids[array_upper(v_ids, 1)];
        v_left := 0;
        exit;
      end if;
      insert into public.rent_log (company_id, property_id, property_name, lease_id, tenant_id, tenant_email, tenant_name,
                                   amount, date_paid, method, applied_to_due_date, note, source,
                                   incoming_payment_id, online_payment_id)
      values (p_company, p_property, v_pname, v_lease, v_tid, v_temail, v_tname,
              v_chunk, p_date_paid, p_method, v_next, concat_ws(' · ', p_note, 'prepayment'), p_source,
              p_incoming_payment, p_online_payment)
      returning id into v_new;
      v_ids := v_ids || v_new;
      v_left := v_left - v_chunk;
      exit when v_i >= 24;
    end loop;
  end if;

  return v_ids;
end;
$$;

revoke execute on function public.rg_apply_payment(uuid, uuid, numeric, date, text, text, text, date, date, uuid, uuid) from public, anon;
grant execute on function public.rg_apply_payment(uuid, uuid, numeric, date, text, text, text, date, date, uuid, uuid) to authenticated, service_role;

create or replace function public.rg_confirm_incoming_payment(p_id uuid, p_property_id uuid default null,
                                                              p_due_date date default null, p_remember boolean default true)
returns jsonb
language plpgsql
set search_path = 'public'
as $function$
declare
  v_in    public.incoming_rent_payments%rowtype;
  v_prop  uuid;
  v_pname text;
  v_tenant text;
  v_ids   uuid[];
begin
  select * into v_in from public.incoming_rent_payments where id = p_id for update;
  if not found then raise exception 'Payment not found'; end if;
  if v_in.status <> 'pending' then raise exception 'Payment is already %', v_in.status; end if;

  v_prop := coalesce(p_property_id, v_in.property_id);
  if v_prop is null then raise exception 'Choose a property for this payment'; end if;

  v_ids := public.rg_apply_payment(
    v_in.company_id, v_prop, v_in.amount, v_in.date_paid, v_in.method,
    nullif(concat_ws(' · ', v_in.memo, 'from ' || v_in.tenant_name), ''), 'email',
    p_due_date, v_in.suggested_due_date, v_in.id, null);

  select p.name into v_pname from public.properties p where p.id = v_prop;
  select s.tenant_name into v_tenant
    from public.rg_rent_status(v_in.company_id, coalesce(v_in.date_paid, current_date)) s
   where s.property_id = v_prop;

  update public.incoming_rent_payments
     set status = 'confirmed', property_id = v_prop, property_name = v_pname,
         rent_log_ids = v_ids, reviewed_at = now(), reviewed_by = auth.uid()
   where id = v_in.id;

  if p_remember and public.rg_normalize_name(v_in.tenant_name) is not null then
    insert into public.tenant_payer_aliases (company_id, property_id, tenant_name, payer_name_norm)
    values (v_in.company_id, v_prop, v_tenant, public.rg_normalize_name(v_in.tenant_name))
    on conflict (company_id, payer_name_norm)
    do update set property_id = excluded.property_id, tenant_name = excluded.tenant_name;
  end if;

  return jsonb_build_object('status', 'confirmed', 'rent_log_ids', to_jsonb(v_ids));
end;
$function$;

-- 2 ─────────────────────────────────────────────────────────────────────────────────────────────
alter table public.companies
  add column if not exists stripe_account_id        text unique,
  add column if not exists stripe_charges_enabled   boolean not null default false,
  add column if not exists stripe_payouts_enabled   boolean not null default false,
  add column if not exists stripe_details_submitted boolean not null default false,
  add column if not exists stripe_onboarded_at      timestamptz;

create or replace function public.trigger_companies_protect_stripe()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  -- Signed-in users (PostgREST runs their requests as authenticated/anon) never set these
  if current_user in ('authenticated', 'anon') and (
       tg_op = 'INSERT' and (new.stripe_account_id is not null or new.stripe_charges_enabled
                             or new.stripe_payouts_enabled or new.stripe_details_submitted
                             or new.stripe_onboarded_at is not null)
    or tg_op = 'UPDATE' and (new.stripe_account_id is distinct from old.stripe_account_id
                             or new.stripe_charges_enabled is distinct from old.stripe_charges_enabled
                             or new.stripe_payouts_enabled is distinct from old.stripe_payouts_enabled
                             or new.stripe_details_submitted is distinct from old.stripe_details_submitted
                             or new.stripe_onboarded_at is distinct from old.stripe_onboarded_at)) then
    raise exception 'Online payment settings are changed through Account > Get paid online.' using errcode = '42501';
  end if;
  return new;
end;
$$;

create trigger trg_companies_protect_stripe
  before insert or update on public.companies
  for each row execute function public.trigger_companies_protect_stripe();

-- 3 ─────────────────────────────────────────────────────────────────────────────────────────────
create table public.online_payments (
  id                          uuid primary key default gen_random_uuid(),
  company_id                  uuid not null references public.companies(id),
  property_id                 uuid not null references public.properties(id),
  lease_id                    uuid references public.leases(id),
  tenant_id                   uuid references public.tenants(id),
  tenant_email                text,
  amount                      numeric(12,2) not null check (amount > 0),
  fee_amount                  numeric(12,2) not null default 0 check (fee_amount >= 0),
  currency                    text not null default 'usd',
  status                      text not null default 'created'
                                check (status in ('created', 'processing', 'succeeded', 'failed', 'expired', 'refunded', 'disputed')),
  stripe_account_id           text,
  stripe_checkout_session_id  text unique,
  stripe_payment_intent_id    text unique,
  failure_reason              text,
  rent_log_ids                uuid[] not null default '{}',
  paid_at                     timestamptz,
  created_at                  timestamptz not null default now(),
  updated_at                  timestamptz not null default now()
);

create index online_payments_company_idx on public.online_payments (company_id, created_at desc);
create index online_payments_lease_idx on public.online_payments (lease_id) where lease_id is not null;
create index online_payments_open_idx on public.online_payments (status) where status in ('created', 'processing');

alter table public.online_payments enable row level security;

create policy online_payments_select on public.online_payments
  for select to authenticated
  using (public.rg_company_access(company_id)
         or tenant_id = public.rg_tenant_id_for_auth_user()
         or (public.rg_auth_email() is not null and lower(tenant_email) = public.rg_auth_email()));

revoke all on public.online_payments from anon, authenticated;
grant select on public.online_payments to authenticated;

alter table public.rent_log
  add constraint rent_log_online_payment_fkey foreign key (online_payment_id) references public.online_payments(id);
create index rent_log_online_payment_idx on public.rent_log (online_payment_id) where online_payment_id is not null;

-- 4 ─────────────────────────────────────────────────────────────────────────────────────────────
alter table public.leases add column if not exists pay_accepts_online boolean not null default true;

-- 5 ─────────────────────────────────────────────────────────────────────────────────────────────
insert into public.notification_kinds (kind, description) values
  ('payment_received', 'Landlord: rent paid online'),
  ('payment_receipt',  'Tenant: receipt for an online payment'),
  ('payment_failed',   'Landlord and tenant: online payment failed or was returned')
on conflict (kind) do nothing;

-- 6 ─────────────────────────────────────────────────────────────────────────────────────────────
revoke execute on function public.rg_tenant_id_for_auth_user() from public, anon;
grant execute on function public.rg_tenant_id_for_auth_user() to authenticated, service_role;
