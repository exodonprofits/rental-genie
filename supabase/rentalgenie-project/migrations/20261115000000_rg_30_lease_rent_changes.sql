-- rg_30: rent changes during a lease (yearly increases, step rent on commercial leases, a renewal at a new rent).
--
-- leases.rent_amount stays the STARTING rent. lease_rent_changes holds each later change: from effective_date on,
-- rent due on or after that date is rent_amount. One live change per lease and date; changes are archived, never
-- deleted, so past balances can be explained.
--
-- rg_rent_schedule charges each due date at the rent in effect on that date (rg_lease_rent_on), so balances,
-- reminders, the monthly summary, the payment inbox matcher and online payments all follow without their own logic.
-- rg_rent_status reports the rent of the latest due date (the current rent). rg_apply_payment splits a prepayment
-- at the rent that will apply to each future month.
--
-- Pages: select current_rent from leases (a computed field: the rent in effect today, America/Chicago) where they
-- show "monthly rent"; list lease_rent_changes for the schedule. Who can read a lease can read its rent changes;
-- only the company (rg_company_access) can add or archive them.

create table if not exists public.lease_rent_changes (
  id             uuid primary key default gen_random_uuid(),
  company_id     uuid not null references public.companies(id),
  lease_id       uuid not null references public.leases(id),
  effective_date date not null,
  rent_amount    numeric(12,2) not null check (rent_amount > 0 and rent_amount < 10000000),
  note           text check (note is null or char_length(note) <= 300),
  created_at     timestamptz not null default now(),
  created_by     uuid default auth.uid(),
  archived_at    timestamptz,
  archived_by    uuid
);

create unique index if not exists lease_rent_changes_one_per_date
  on public.lease_rent_changes (lease_id, effective_date) where archived_at is null;
create index if not exists lease_rent_changes_company on public.lease_rent_changes (company_id);

-- company_id always comes from the lease (a page can't point a change at another company); the change must start
-- after the lease does (a change on the start date is the starting rent: edit the lease instead); the lease and
-- the amount of a saved change can't be edited (archive it and add a new one), only its note and archived_at.
create or replace function public.rg_lease_rent_changes_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_lease record;
begin
  if tg_op = 'UPDATE' then
    if new.lease_id is distinct from old.lease_id or new.company_id is distinct from old.company_id
       or new.effective_date is distinct from old.effective_date or new.rent_amount is distinct from old.rent_amount
       or new.created_by is distinct from old.created_by or new.created_at is distinct from old.created_at then
      raise exception 'A saved rent change can''t be edited. Remove it and add a new one.' using errcode = '22023';
    end if;
    if old.archived_at is not null and new.archived_at is null then
      raise exception 'A removed rent change can''t be restored. Add it again.' using errcode = '22023';
    end if;
    if new.archived_at is not null and old.archived_at is null then
      new.archived_by := auth.uid();
    end if;
    new.note := nullif(btrim(new.note), '');
    return new;
  end if;

  select l.id, l.company_id, l.lease_start, l.archived_at into v_lease
    from public.leases l where l.id = new.lease_id;
  if v_lease.id is null then
    raise exception 'That lease doesn''t exist.' using errcode = '22023';
  end if;
  if v_lease.archived_at is not null then
    raise exception 'That lease is archived.' using errcode = '22023';
  end if;
  if v_lease.lease_start is not null and new.effective_date <= v_lease.lease_start then
    raise exception 'A rent change has to start after the lease does (%). To change the starting rent, edit the lease.',
      to_char(v_lease.lease_start, 'Mon DD, YYYY') using errcode = '22023';
  end if;
  new.company_id  := v_lease.company_id;
  new.note        := nullif(btrim(new.note), '');
  new.created_at  := now();
  new.created_by  := auth.uid();
  new.archived_at := null;
  new.archived_by := null;
  return new;
end;
$$;

drop trigger if exists trg_lease_rent_changes_guard on public.lease_rent_changes;
create trigger trg_lease_rent_changes_guard
  before insert or update on public.lease_rent_changes
  for each row execute function public.rg_lease_rent_changes_guard();

alter table public.lease_rent_changes enable row level security;
revoke all on public.lease_rent_changes from anon, authenticated;
grant select, insert, update on public.lease_rent_changes to authenticated;
grant all on public.lease_rent_changes to service_role;

drop policy if exists lease_rent_changes_select on public.lease_rent_changes;
create policy lease_rent_changes_select on public.lease_rent_changes for select to authenticated
  using (exists (select 1 from public.leases l where l.id = lease_rent_changes.lease_id));
drop policy if exists lease_rent_changes_insert on public.lease_rent_changes;
create policy lease_rent_changes_insert on public.lease_rent_changes for insert to authenticated
  with check (public.rg_company_access(company_id));
drop policy if exists lease_rent_changes_update on public.lease_rent_changes;
create policy lease_rent_changes_update on public.lease_rent_changes for update to authenticated
  using (public.rg_company_access(company_id)) with check (public.rg_company_access(company_id));

-- The rent change in effect on a date, or null when the starting rent applies (callers coalesce with
-- leases.rent_amount). Runs as the caller, so it only sees changes the caller may read.
create or replace function public.rg_lease_rent_on(p_lease uuid, p_on date)
returns numeric
language sql
stable
set search_path = ''
as $$
  select rc.rent_amount
    from public.lease_rent_changes rc
   where rc.lease_id = p_lease and rc.archived_at is null and rc.effective_date <= p_on
   order by rc.effective_date desc
   limit 1;
$$;
revoke all on function public.rg_lease_rent_on(uuid, date) from public, anon;
grant execute on function public.rg_lease_rent_on(uuid, date) to authenticated, service_role;

-- PostgREST computed field: .select("rent_amount, current_rent") on leases
create or replace function public.current_rent(l public.leases)
returns numeric
language sql
stable
set search_path = ''
as $$
  select coalesce(public.rg_lease_rent_on(l.id, (now() at time zone 'America/Chicago')::date), l.rent_amount);
$$;
revoke all on function public.current_rent(public.leases) from public, anon;
grant execute on function public.current_rent(public.leases) to authenticated, service_role;

-- Schedule: unchanged except that each due date is charged at the rent in effect on it, and rows come back in
-- due-date order per property (pages take the last row as the current month).
create or replace function public.rg_rent_schedule(p_company_id uuid DEFAULT NULL::uuid, p_as_of date DEFAULT CURRENT_DATE)
 RETURNS TABLE(property_id uuid, property_name text, company_id uuid, lease_id uuid, tenant_name text, lease_state text, rent_amount numeric, due_day integer, grace_days integer, lease_end date, charge_end date, due_date date, paid numeric, balance numeric)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
with lease_pick as (
  select distinct on (p.id)
    p.id as property_id, p.name as property_name, p.company_id,
    l.id as lease_id, l.tenant_name,
    lower(coalesce(l.status, ''))     as lstatus,
    lower(coalesce(l.lease_type, '')) as ltype,
    l.lease_start, l.lease_end, l.terminated_date,
    l.rent_amount::numeric as rent_amount,
    coalesce(l.rent_due_day, l.due_day, extract(day from l.lease_start)::int) as due_day,
    coalesce(l.grace_period, l.late_fee_grace_days, 0)::int as grace_days
  from public.properties p
  join public.leases l
    on l.property_id = p.id
    or (l.property_id is null and l.property_name = p.name
        and l.company_id is not distinct from p.company_id)
  where p.archived_at is null
    and l.archived_at is null
    and lower(coalesce(l.status, '')) <> 'draft'
    and (p_company_id is null or p.company_id = p_company_id)
    and l.lease_start is not null
    and l.lease_start <= p_as_of
    and coalesce(l.rent_amount, 0) > 0
  order by p.id, l.lease_start desc
),
windowed as (
  select lp.*,
    case
      when lp.terminated_date is not null then least(lp.terminated_date, p_as_of)
      when lp.lstatus = 'terminated'      then least(coalesce(lp.lease_end, p_as_of), p_as_of)
      else p_as_of
    end as charge_end,
    case
      when lp.terminated_date is not null or lp.lstatus = 'terminated' then 'ended'
      when lp.ltype like '%month%' or lp.ltype = 'm2m'
        or lp.lstatus in ('month_to_month', 'holdover')             then 'month_to_month'
      when lp.lease_end is not null and lp.lease_end < p_as_of      then 'holdover'
      else 'active'
    end as lease_state
  from lease_pick lp
),
dues as (
  select w.property_id,
         (m::date + (least(w.due_day,
            extract(day from (m + interval '1 month' - interval '1 day'))::int) - 1)) as due_date
  from windowed w
  cross join lateral generate_series(
    date_trunc('month', w.lease_start),
    date_trunc('month', w.charge_end),
    interval '1 month') as m
),
pay as (
  select w.property_id, r.applied_to_due_date as due_date, sum(r.amount::numeric) as paid
  from windowed w
  join public.rent_log r
    on (r.property_id = w.property_id
        or (r.property_id is null and r.property_name = w.property_name))
   and r.company_id is not distinct from w.company_id
   and r.archived_at is null
   and r.applied_to_due_date is not null
  group by w.property_id, r.applied_to_due_date
),
charged as (
  select w.*, d.due_date,
         coalesce(public.rg_lease_rent_on(w.lease_id, d.due_date), w.rent_amount) as rent_due
  from windowed w
  join dues d on d.property_id = w.property_id
  where d.due_date >= w.lease_start and d.due_date <= w.charge_end
)
select
  c.property_id, c.property_name, c.company_id, c.lease_id, c.tenant_name, c.lease_state,
  c.rent_due, c.due_day, c.grace_days, c.lease_end, c.charge_end,
  c.due_date,
  coalesce(pay.paid, 0),
  greatest(c.rent_due - coalesce(pay.paid, 0), 0)
from charged c
left join pay on pay.property_id = c.property_id and pay.due_date = c.due_date
order by c.property_id, c.due_date;
$function$;

-- Status: the head row is now the latest due date, so rent_amount is the current rent.
create or replace function public.rg_rent_status(p_company_id uuid DEFAULT NULL::uuid, p_as_of date DEFAULT CURRENT_DATE)
 RETURNS TABLE(property_id uuid, property_name text, lease_id uuid, tenant_name text, lease_state text, rent_amount numeric, due_day integer, grace_days integer, lease_end date, charge_end date, periods_due integer, periods_unpaid integer, total_due numeric, total_paid numeric, balance numeric, oldest_unpaid_due date, current_due_date date, current_paid numeric, current_balance numeric, days_overdue integer, is_late boolean)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
with s as (
  select * from public.rg_rent_schedule(p_company_id, p_as_of)
),
agg as (
  select s.property_id,
         count(*)::int                                        as periods_due,
         count(*) filter (where s.balance > 0.01)::int        as periods_unpaid,
         sum(s.rent_amount)                                   as total_due,
         sum(least(s.paid, s.rent_amount))                    as total_paid,
         sum(s.balance)                                       as balance,
         min(s.due_date) filter (where s.balance > 0.01)      as oldest_unpaid_due,
         max(s.due_date)                                      as current_due_date
  from s group by s.property_id
),
head as (
  select distinct on (s.property_id) s.*
  from s order by s.property_id, s.due_date desc
)
select h.property_id, h.property_name, h.lease_id, h.tenant_name, h.lease_state,
  h.rent_amount, h.due_day, h.grace_days, h.lease_end, h.charge_end,
  a.periods_due, a.periods_unpaid, a.total_due, a.total_paid, a.balance,
  a.oldest_unpaid_due, a.current_due_date,
  coalesce(cur.paid, 0), coalesce(cur.balance, 0),
  case when a.oldest_unpaid_due is null then 0 else (p_as_of - a.oldest_unpaid_due) end,
  (a.oldest_unpaid_due is not null and p_as_of > a.oldest_unpaid_due + h.grace_days)
from head h
join agg a on a.property_id = h.property_id
left join s cur on cur.property_id = h.property_id and cur.due_date = a.current_due_date;
$function$;

-- Payments: unchanged except that each prepaid month is a piece of the rent that will apply to it.
create or replace function public.rg_apply_payment(p_company uuid, p_property uuid, p_amount numeric, p_date_paid date, p_method text, p_note text, p_source text, p_due_date date DEFAULT NULL::date, p_fallback_due date DEFAULT NULL::date, p_incoming_payment uuid DEFAULT NULL::uuid, p_online_payment uuid DEFAULT NULL::uuid)
 RETURNS uuid[]
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_asof     date := coalesce(p_date_paid, current_date);
  v_pname    text;
  v_lease    uuid;
  v_tname    text;
  v_tid      uuid;
  v_temail   text;
  v_base     numeric;
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

  select s.lease_id, s.tenant_name into v_lease, v_tname
    from public.rg_rent_status(p_company, v_asof) s where s.property_id = p_property;
  if v_lease is not null then
    select l.tenant_id, nullif(btrim(l.tenant_email), ''), l.rent_amount into v_tid, v_temail, v_base
      from public.leases l where l.id = v_lease;
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

  if v_left > 0.01 then
    select max(s.due_date), max(s.due_day)
      into v_last_due, v_due_day
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
      v_rent := case when v_lease is null then null
                     else coalesce(public.rg_lease_rent_on(v_lease, v_next), v_base) end;
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
$function$;

