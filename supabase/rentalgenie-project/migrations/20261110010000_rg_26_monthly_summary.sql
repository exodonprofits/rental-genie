-- rg_26: monthly summary email to the landlord (the last "Coming soon" switch on Account > Notifications).
--
-- rg_monthly_summary(p_today) runs from pg_cron on the 1st of each month at 14:10 UTC and reports on the
-- month that just ended ("today" is the date in America/Chicago). One email per company, through the
-- rg_17 outbox under 'monthly_summary:<company>:<YYYY-MM>' (so a re-run sends nothing new), to the
-- company owner. Owner switch user_metadata.notifications.monthlySummary, missing = on. (The older
-- 'monthly' key isn't used: the page saved it as false while the switch was disabled, so it was never a
-- real choice.)
--
-- Contents, all from the database (rent from rg_rent_schedule, the single source of truth):
--   - per property: rent collected in the month (by date received), rent due in the month and what
--     of it is still unpaid, and the balance owed today;
--   - expenses logged in the month, top categories;
--   - open repairs (high/emergency counted), leases ending in the next 60 days, payment-inbox items
--     waiting to be confirmed;
--   - payments that look entered twice (same rule as Reports: several payments on one due date adding
--     up to at least twice the largest, or the same amount on the same day), last 18 months.
-- Companies with no properties are skipped.

create or replace function public.rg_monthly_summary(p_today date default (now() at time zone 'America/Chicago')::date)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  c          record;
  r          record;
  v_from     date := date_trunc('month', p_today - 1)::date;   -- month being reported
  v_to       date := (date_trunc('month', p_today - 1) + interval '1 month - 1 day')::date;
  v_month    text := to_char(date_trunc('month', p_today - 1), 'FMMonth YYYY');
  v_lines    text;
  v_body     text;
  v_coll     numeric; v_due numeric; v_unpaid numeric; v_owed numeric; v_exp numeric;
  v_cats     text;
  v_open     integer; v_urgent integer; v_ending integer; v_inbox integer; v_dupes integer;
  v_id       bigint;
  v_queued   integer := 0;
begin
  for c in select co.id from public.companies co
            where exists (select 1 from public.properties p where p.company_id = co.id and p.archived_at is null) loop
    begin
      v_lines := ''; v_coll := 0; v_due := 0; v_unpaid := 0; v_owed := 0;
      for r in
        with sched as (select * from public.rg_rent_schedule(c.id, p_today - 1)),
        props as (select p.id, p.name from public.properties p where p.company_id = c.id and p.archived_at is null)
        select pr.name,
               coalesce((select sum(l.amount) from public.rent_log l
                          where l.company_id = c.id and l.archived_at is null
                            and (l.property_id = pr.id or (l.property_id is null and l.property_name = pr.name))
                            and l.date_paid between v_from and v_to), 0) as collected,
               coalesce((select sum(s.rent_amount) from sched s where s.property_id = pr.id and s.due_date between v_from and v_to), 0) as due,
               coalesce((select sum(s.balance) from sched s where s.property_id = pr.id and s.due_date between v_from and v_to), 0) as unpaid,
               coalesce((select sum(s.balance) from sched s where s.property_id = pr.id), 0) as owed
          from props pr
         order by pr.name
      loop
        v_lines := v_lines || '• ' || r.name || ': collected ' || public.rg_money(r.collected)
                   || case when r.due > 0 then ' · due ' || public.rg_money(r.due)
                        || case when r.unpaid > 0 then ' (' || public.rg_money(r.unpaid) || ' unpaid)' else ' (paid)' end
                      else ' · no rent due' end
                   || case when r.owed > 0 then ' · owes ' || public.rg_money(r.owed) || ' in total' else '' end
                   || chr(10);
        v_coll := v_coll + r.collected; v_due := v_due + r.due; v_unpaid := v_unpaid + r.unpaid; v_owed := v_owed + r.owed;
      end loop;

      select coalesce(sum(e.amount), 0) into v_exp
        from public.expenses e
       where e.company_id = c.id and e.archived_at is null and e.date_paid between v_from and v_to;
      select string_agg(x.category || ' ' || public.rg_money(x.total), ', ' order by x.total desc) into v_cats
        from (select coalesce(nullif(e.category, ''), 'Other') as category, sum(e.amount) as total
                from public.expenses e
               where e.company_id = c.id and e.archived_at is null and e.date_paid between v_from and v_to
               group by 1 order by 2 desc limit 3) x;

      select count(*),
             count(*) filter (where m.urgency_level in ('High', 'Emergency'))
        into v_open, v_urgent
        from public.maintenance_requests m
       where m.company_id = c.id and m.archived_at is null
         and lower(coalesce(m.status, '')) not in ('resolved', 'closed', 'completed', 'complete', 'done');

      select count(*) into v_ending
        from public.leases l
       where l.company_id = c.id and l.archived_at is null and l.lease_end between p_today and p_today + 60
         and lower(coalesce(l.status, '')) not in ('draft', 'terminated', 'ended', 'month_to_month', 'holdover')
         and lower(coalesce(l.lease_type, '')) not like '%month%' and l.terminated_date is null;

      select count(*) into v_inbox from public.incoming_rent_payments i where i.company_id = c.id and i.status = 'pending';

      select count(*) into v_dupes from (
        select 1 from public.rent_log l
         where l.company_id = c.id and l.archived_at is null and l.applied_to_due_date is not null
           and l.date_paid >= p_today - interval '18 months'
         group by coalesce(l.property_id::text, l.property_name), l.applied_to_due_date
        having count(*) >= 2 and sum(l.amount) >= 2 * max(l.amount)
        union all
        select 1 from public.rent_log l
         where l.company_id = c.id and l.archived_at is null and l.applied_to_due_date is null
           and l.date_paid >= p_today - interval '18 months'
         group by coalesce(l.property_id::text, l.property_name), l.date_paid, l.amount
        having count(*) >= 2) d;

      v_body := 'Your Rental Genie summary for ' || v_month || '.' || chr(10) || chr(10)
        || 'RENT' || chr(10)
        || 'Collected in ' || to_char(v_from, 'FMMonth') || ': ' || public.rg_money(v_coll) || chr(10)
        || 'Due in ' || to_char(v_from, 'FMMonth') || ': ' || public.rg_money(v_due)
        || case when v_unpaid > 0 then ', ' || public.rg_money(v_unpaid) || ' of it still unpaid' else ', all paid' end || chr(10)
        || 'Owed in total today: ' || public.rg_money(v_owed) || chr(10) || chr(10)
        || v_lines || chr(10)
        || 'EXPENSES' || chr(10)
        || 'Logged in ' || to_char(v_from, 'FMMonth') || ': ' || public.rg_money(v_exp)
        || coalesce(' (' || v_cats || ')', '') || chr(10) || chr(10)
        || 'TO DO' || chr(10)
        || '• Open repairs: ' || v_open || case when v_urgent > 0 then ' (' || v_urgent || ' high priority or emergency)' else '' end || chr(10)
        || '• Leases ending in the next 60 days: ' || v_ending || chr(10)
        || case when v_inbox > 0 then '• Forwarded payments waiting to be confirmed: ' || v_inbox || chr(10) else '' end
        || case when v_dupes > 0 then '• Payments that look entered twice: ' || v_dupes
             || '. They count as rent until archived; see "Payments to check" in Reports.' || chr(10) else '' end
        || chr(10)
        || 'Full numbers, including net after mortgage and fixed costs:' || chr(10)
        || 'https://rentalgenieai.com/reports-analytics.html' || chr(10) || chr(10)
        || '— Rental Genie' || chr(10) || 'Turn this email off in Account > Notifications.';

      v_id := public.rg_landlord_alert_prepare('monthly_summary', c.id,
        'monthly_summary:' || c.id || ':' || to_char(v_from, 'YYYY-MM'), 'monthlySummary',
        'Your ' || v_month || ' summary: ' || public.rg_money(v_coll) || ' collected'
          || case when v_owed > 0 then ', ' || public.rg_money(v_owed) || ' owed' else '' end,
        v_body);
      if v_id is not null then perform public.rg_notification_kick(v_id); v_queued := v_queued + 1; end if;
    exception when others then
      raise warning 'monthly summary for company % failed: %', c.id, sqlerrm;
    end;
  end loop;
  return v_queued;
end;
$$;

revoke execute on function public.rg_monthly_summary(date) from public, anon, authenticated;

select cron.schedule('rg-monthly-summary', '10 14 1 * *', 'select public.rg_monthly_summary()');
