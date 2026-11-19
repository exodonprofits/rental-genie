-- rg_35: an email the day after a fixed-term lease's end date (first day of holdover), so a lease doesn't drift into
-- holdover unnoticed. Part of rg_daily_reminders (pg_cron rg-daily-reminders, 14:05 UTC, today in Chicago), owner
-- switch `lease` like the 30-day warning, key lease_expired:<company>:<day>. The Properties card shows the matching
-- "Lease expired" prompt for as long as the lease stays in holdover.

insert into public.notification_kinds (kind, description) values
  ('lease_expired', 'Landlord: a fixed-term lease reached its end date and is now in holdover')
on conflict (kind) do nothing;

create or replace function public.rg_daily_reminders(p_today date default (now() at time zone 'America/Chicago')::date)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  c        record;
  r        record;
  v_lines  text;
  v_total  numeric;
  v_n      integer;
  v_id     bigint;
  v_queued integer := 0;
  v_link   text := 'https://rentalgenieai.com/lease-rent-center.html?filter=attention&view=ledger';
begin
  for c in select id from public.companies loop
    begin
      -- Rent due in 3 days
      v_lines := ''; v_total := 0; v_n := 0;
      for r in
        select s.property_name, s.tenant_name, s.balance, s.paid
          from public.rg_rent_schedule(c.id, p_today + 3) s
         where s.due_date = p_today + 3 and s.balance > 0 and s.lease_state <> 'ended'
         order by s.property_name
      loop
        v_lines := v_lines || '• ' || r.property_name || coalesce(' (' || nullif(r.tenant_name, '') || ')', '')
                   || ': ' || public.rg_money(r.balance)
                   || case when r.paid > 0 then ' still due (' || public.rg_money(r.paid) || ' paid)' else '' end || chr(10);
        v_total := v_total + r.balance; v_n := v_n + 1;
      end loop;
      if v_n > 0 then
        v_id := public.rg_landlord_alert_prepare('rent_due', c.id, 'rent_due:' || c.id || ':' || (p_today + 3), 'rentDue',
          'Rent due ' || to_char(p_today + 3, 'Dy Mon FMDD') || ': ' || v_n || ' propert' || case when v_n = 1 then 'y' else 'ies' end
            || ', ' || public.rg_money(v_total),
          'Rent is due in 3 days, on ' || to_char(p_today + 3, 'FMDay, Mon FMDD') || ':' || chr(10) || chr(10) || v_lines || chr(10)
            || 'Total due: ' || public.rg_money(v_total) || chr(10) || chr(10)
            || 'See the ledger:' || chr(10) || v_link || chr(10) || chr(10)
            || '— Rental Genie' || chr(10) || 'Turn these emails off in Account > Notifications.');
        if v_id is not null then perform public.rg_notification_kick(v_id); v_queued := v_queued + 1; end if;
      end if;

      -- Rent that became overdue today (grace period ended yesterday)
      v_lines := ''; v_total := 0; v_n := 0;
      for r in
        select s.property_name, s.tenant_name, s.balance, s.due_date, s.grace_days
          from public.rg_rent_schedule(c.id, p_today) s
         where s.due_date + coalesce(s.grace_days, 0) + 1 = p_today and s.balance > 0
         order by s.property_name
      loop
        v_lines := v_lines || '• ' || r.property_name || coalesce(' (' || nullif(r.tenant_name, '') || ')', '')
                   || ': ' || public.rg_money(r.balance) || ' unpaid, due ' || to_char(r.due_date, 'Mon FMDD')
                   || case when coalesce(r.grace_days, 0) > 0 then ', ' || r.grace_days || '-day grace period ended' else '' end || chr(10);
        v_total := v_total + r.balance; v_n := v_n + 1;
      end loop;
      if v_n > 0 then
        v_id := public.rg_landlord_alert_prepare('rent_overdue', c.id, 'rent_overdue:' || c.id || ':' || p_today, 'overdue',
          'Rent overdue: ' || v_n || ' propert' || case when v_n = 1 then 'y' else 'ies' end || ', ' || public.rg_money(v_total),
          'These rents are now past their grace period and not fully paid:' || chr(10) || chr(10) || v_lines || chr(10)
            || 'Total overdue: ' || public.rg_money(v_total) || chr(10) || chr(10)
            || 'If a payment came in, log it so the balance updates. A payment you forwarded to the payment inbox needs confirming there.' || chr(10) || chr(10)
            || 'See the ledger:' || chr(10) || v_link || chr(10) || chr(10)
            || '— Rental Genie' || chr(10) || 'Turn these emails off in Account > Notifications.');
        if v_id is not null then perform public.rg_notification_kick(v_id); v_queued := v_queued + 1; end if;
      end if;

      -- Fixed-term leases ending in 30 days
      v_lines := ''; v_n := 0;
      for r in
        select l.property_name, l.tenant_name, l.lease_end
          from public.leases l
         where l.company_id = c.id and l.archived_at is null and l.lease_end = p_today + 30
           and lower(coalesce(l.status, '')) not in ('draft', 'terminated', 'ended', 'month_to_month', 'holdover')
           and lower(coalesce(l.lease_type, '')) not like '%month%' and l.terminated_date is null
         order by l.property_name
      loop
        v_lines := v_lines || '• ' || coalesce(r.property_name, 'A property') || coalesce(' (' || nullif(r.tenant_name, '') || ')', '')
                   || ': ends ' || to_char(r.lease_end, 'FMDay, Mon FMDD, YYYY') || chr(10);
        v_n := v_n + 1;
      end loop;
      if v_n > 0 then
        v_id := public.rg_landlord_alert_prepare('lease_expiry', c.id, 'lease_expiry:' || c.id || ':' || p_today, 'lease',
          'Lease ending in 30 days: ' || v_n || ' lease' || case when v_n = 1 then '' else 's' end,
          'These leases end in 30 days:' || chr(10) || chr(10) || v_lines || chr(10)
            || 'Decide whether to renew, switch to month-to-month, or plan the move-out. If the tenant stays past the end date without a change, Rental Genie keeps charging rent as a holdover.' || chr(10) || chr(10)
            || 'Open Lease & Rent:' || chr(10) || 'https://rentalgenieai.com/lease-rent-center.html' || chr(10) || chr(10)
            || '— Rental Genie' || chr(10) || 'Turn these emails off in Account > Notifications.');
        if v_id is not null then perform public.rg_notification_kick(v_id); v_queued := v_queued + 1; end if;
      end if;
      -- Leases that expired yesterday: today is the first day of holdover (rg_35). Same filters as the 30-day
      -- warning, and not when a later lease on the property has already started (that one replaced it).
      v_lines := ''; v_n := 0;
      for r in
        select l.property_name, l.tenant_name, l.lease_end
          from public.leases l
         where l.company_id = c.id and l.archived_at is null and l.lease_end = p_today - 1
           and lower(coalesce(l.status, '')) not in ('draft', 'terminated', 'ended', 'month_to_month', 'holdover')
           and lower(coalesce(l.lease_type, '')) not like '%month%' and l.terminated_date is null
           and not exists (select 1 from public.leases n
                            where n.property_id = l.property_id and n.id <> l.id and n.archived_at is null
                              and lower(coalesce(n.status, '')) <> 'draft'
                              and n.lease_start > l.lease_start and n.lease_start <= p_today)
         order by l.property_name
      loop
        v_lines := v_lines || '• ' || coalesce(r.property_name, 'A property') || coalesce(' (' || nullif(r.tenant_name, '') || ')', '')
                   || ': ended ' || to_char(r.lease_end, 'FMDay, Mon FMDD, YYYY') || chr(10);
        v_n := v_n + 1;
      end loop;
      if v_n > 0 then
        v_id := public.rg_landlord_alert_prepare('lease_expired', c.id, 'lease_expired:' || c.id || ':' || p_today, 'lease',
          'Lease expired: ' || v_n || ' lease' || case when v_n = 1 then '' else 's' end || ' now in holdover',
          'These leases reached their end date yesterday:' || chr(10) || chr(10) || v_lines || chr(10)
            || 'Rental Genie keeps charging rent as a holdover until you choose what happens next:' || chr(10)
            || '• Renew: add the new lease (the old one stops counting when it starts).' || chr(10)
            || '• Month-to-month: edit the lease and set Lease type to Month-to-month.' || chr(10)
            || '• Moving out: terminate the lease with the move-out date; rent stops and the property turns Vacant.' || chr(10) || chr(10)
            || 'Open Lease & Rent:' || chr(10) || 'https://rentalgenieai.com/lease-rent-center.html' || chr(10) || chr(10)
            || '— Rental Genie' || chr(10) || 'Turn these emails off in Account > Notifications.');
        if v_id is not null then perform public.rg_notification_kick(v_id); v_queued := v_queued + 1; end if;
      end if;
    exception when others then
      raise warning 'daily reminders for company % failed: %', c.id, sqlerrm;
    end;
  end loop;
  return v_queued;
end;
$$;

revoke execute on function public.rg_daily_reminders(date) from public, anon, authenticated;
