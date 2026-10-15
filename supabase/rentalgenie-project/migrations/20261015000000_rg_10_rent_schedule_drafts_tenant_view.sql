-- rg_10: rent schedule skips draft leases; tenant-scoped schedule (pre-launch audit F-12, F-17)
--
-- 1. rg_rent_schedule picked the newest lease per property whatever its status, so a drafted
--    renewal (status 'draft', not yet signed) replaced the signed lease and was charged rent.
--    Draft leases are now skipped; the signed lease stays in force until the renewal is signed.
--    (No draft leases existed when this was written, so live balances did not change.)
--
-- 2. Tenant pages computed rent in the browser because tenants can't read properties, which
--    rg_rent_schedule joins (it runs as the caller, under row-level security).
--    rg_my_rent_schedule returns the same rows, limited to the signed-in tenant's own leases,
--    so tenant pages read the database figures like the landlord pages do.

create or replace function public.rg_rent_schedule(p_company_id uuid default null, p_as_of date default current_date)
returns table(property_id uuid, property_name text, company_id uuid, lease_id uuid, tenant_name text,
              lease_state text, rent_amount numeric, due_day integer, grace_days integer, lease_end date,
              charge_end date, due_date date, paid numeric, balance numeric)
language sql
stable
set search_path to 'public'
as $function$
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
)
select
  w.property_id, w.property_name, w.company_id, w.lease_id, w.tenant_name, w.lease_state,
  w.rent_amount, w.due_day, w.grace_days, w.lease_end, w.charge_end,
  d.due_date,
  coalesce(pay.paid, 0),
  greatest(w.rent_amount - coalesce(pay.paid, 0), 0)
from windowed w
join dues d on d.property_id = w.property_id
left join pay on pay.property_id = d.property_id and pay.due_date = d.due_date
where d.due_date >= w.lease_start and d.due_date <= w.charge_end;
$function$;

create or replace function public.rg_my_rent_schedule(p_as_of date default current_date)
returns table(property_id uuid, property_name text, company_id uuid, lease_id uuid, tenant_name text,
              lease_state text, rent_amount numeric, due_day integer, grace_days integer, lease_end date,
              charge_end date, due_date date, paid numeric, balance numeric)
language sql
stable
security definer
set search_path to 'public'
set row_security to 'off'
as $function$
  with mine as (
    select l.id, l.company_id
    from public.leases l
    where l.archived_at is null
      and l.company_id is not null
      and (l.tenant_id = public.rg_tenant_id_for_auth_user()
           or (public.rg_auth_email() is not null and lower(l.tenant_email) = public.rg_auth_email()))
  )
  select s.*
  from (select distinct company_id from mine) c
  cross join lateral public.rg_rent_schedule(c.company_id, p_as_of) s
  where s.lease_id in (select id from mine);
$function$;

revoke execute on function public.rg_my_rent_schedule(date) from public, anon;
grant execute on function public.rg_my_rent_schedule(date) to authenticated;
