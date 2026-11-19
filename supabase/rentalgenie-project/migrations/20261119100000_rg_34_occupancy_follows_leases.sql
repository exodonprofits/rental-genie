-- rg_34: the occupancy landlords see follows the leases.
--
-- properties has two status columns. rg_sync_property_status (run by the leases trigger) kept `status`
-- (occupied / vacant) in step, but every page shows `occupancy_status` (tenant_occupied / owner_occupied / vacant /
-- renovation / off_market), which nothing updated: a terminated lease left the property "Tenant occupied".
--
-- Now the same sync also moves occupancy_status, only between the two lease-driven values:
--   no lease in force  and occupancy_status = tenant_occupied        -> vacant
--   a lease in force   and occupancy_status is vacant or not set     -> tenant_occupied
-- owner_occupied, renovation and off_market are the landlord's choice and never change. A property with no lease
-- records at all is left alone (the landlord may not have entered the lease yet).
--
-- A termination dated in the future keeps the property occupied until that date (before, status flipped the
-- moment the lease was marked terminated); pg_cron job rg-property-status-sync re-checks every property with a
-- lease each night just after midnight Chicago time, so that date and lease starts take effect on their own.
-- Holdover is unchanged: a signed fixed-term lease past its end date still counts as in force (rent still accrues),
-- unless a later lease on the same property has started (that one replaced it).

create or replace function public.rg_sync_property_status(p_property_id uuid)
returns void language plpgsql set search_path = '' as $$
declare v_occupied boolean; v_today date := (now() at time zone 'America/Chicago')::date;
begin
  if p_property_id is null then return; end if;
  if not exists (select 1 from public.leases l where l.property_id = p_property_id and l.archived_at is null) then
    return;
  end if;
  select exists (
    select 1 from public.leases l
     where l.property_id = p_property_id
       and l.archived_at is null
       and lower(coalesce(l.status, '')) <> 'draft'
       and (l.lease_start is null or l.lease_start <= v_today)
       and (l.terminated_date is null or l.terminated_date > v_today)
       and not (lower(coalesce(l.status, '')) = 'terminated' and l.terminated_date is null)
       -- a lease replaced by a later one that has started no longer counts (as in rg_rent_schedule), even if it
       -- still says "signed"; otherwise an old lease would keep the property occupied as a holdover
       and not exists (select 1 from public.leases n
                        where n.property_id = l.property_id and n.id <> l.id and n.archived_at is null
                          and lower(coalesce(n.status, '')) <> 'draft'
                          and n.lease_start > coalesce(l.lease_start, '-infinity'::date) and n.lease_start <= v_today)
       and (l.lease_end is null or l.lease_end >= v_today
            or lower(coalesce(l.status, '')) in ('holdover', 'month_to_month', 'signed', 'active', 'current', 'terminated')
            or lower(coalesce(l.lease_type, '')) like '%month%')
  ) into v_occupied;
  update public.properties p
     set status = case when v_occupied then 'occupied' else 'vacant' end,
         occupancy_status = case
           when v_occupied and coalesce(p.occupancy_status, '') in ('', 'vacant') then 'tenant_occupied'
           when not v_occupied and p.occupancy_status = 'tenant_occupied' then 'vacant'
           else p.occupancy_status end
   where p.id = p_property_id
     and (p.status is distinct from case when v_occupied then 'occupied' else 'vacant' end
          or (v_occupied and coalesce(p.occupancy_status, '') in ('', 'vacant'))
          or (not v_occupied and p.occupancy_status = 'tenant_occupied'));
end;
$$;

-- Nightly: every non-archived property that has a lease.
create or replace function public.rg_sync_all_property_status()
returns int language plpgsql security definer set search_path = '' as $$
declare r record; n int := 0;
begin
  for r in select distinct p.id from public.properties p join public.leases l on l.property_id = p.id
            where p.archived_at is null and l.archived_at is null loop
    perform public.rg_sync_property_status(r.id);
    n := n + 1;
  end loop;
  return n;
end;
$$;
revoke all on function public.rg_sync_all_property_status() from public, anon, authenticated;

select cron.schedule('rg-property-status-sync', '3 6 * * *', 'select public.rg_sync_all_property_status()');

-- Bring today's data in line (Port Charlotte and Saint Charles Home had terminated leases and showed "Tenant occupied").
select public.rg_sync_all_property_status();
