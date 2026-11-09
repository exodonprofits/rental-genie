-- rg_25: tell the tenant when their repair is scheduled, assigned, in progress or completed.
--
-- AFTER UPDATE on maintenance_requests: compares old and new and, when something the tenant cares
-- about changed, writes one in-app message and queues one email through the rg_17 outbox:
--   - scheduled_at set or changed to a new time      -> "Scheduled: Tuesday, Dec 3 at 10:00 AM" (Central)
--   - assigned_vendor set or changed                  -> "Assigned to: Ace Plumbing"
--   - status Open -> In Progress                      -> "Status: In progress"
--   - status -> Resolved                              -> "Marked complete"
-- Changes saved together go out as one message. The event key is
-- 'repair_update:<request id>:<md5(status|scheduled_at|vendor)>', so the same state is never
-- announced twice. Same rules as the acknowledgment (rg_17): only repairs filed by a tenant (not
-- logged by a company member), recipient from the tenant and lease records, current lease only.
-- The owner can turn these off (Account > Notifications, notifications.tenantRepairUpdates;
-- missing = on); off writes nothing to the tenant and logs the email as skipped. Errors are caught,
-- so saving a repair never fails because of this.

create or replace function public.rg_repair_update_prepare(o public.maintenance_requests, r public.maintenance_requests)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_lines   text := '';
  v_key     text;
  v_tenant  uuid;
  v_lease_em text;
  v_lease_pr uuid;
  v_found   boolean := false;
  v_email   text;
  v_on      boolean;
  v_prop    uuid;
  v_body    text;
  v_subject text;
  v_id      bigint;
  v_done    boolean := r.status = 'Resolved' and o.status is distinct from 'Resolved';
begin
  if r.archived_at is not null then return null; end if;

  -- What changed that the tenant should hear about
  if r.scheduled_at is not null and r.scheduled_at is distinct from o.scheduled_at and not v_done then
    v_lines := v_lines || '• Scheduled: ' || to_char(r.scheduled_at at time zone 'America/Chicago', 'FMDay, Mon FMDD "at" FMHH12:MI AM') || ' (Central time)' || chr(10);
  end if;
  if nullif(btrim(r.assigned_vendor), '') is not null and btrim(r.assigned_vendor) is distinct from btrim(coalesce(o.assigned_vendor, '')) and not v_done then
    v_lines := v_lines || '• Assigned to: ' || btrim(r.assigned_vendor) || chr(10);
  end if;
  if r.status = 'In Progress' and o.status is distinct from 'In Progress' then
    v_lines := v_lines || '• Status: In progress' || chr(10);
  end if;
  if v_done then
    v_lines := v_lines || '• Marked complete. If anything still isn''t right, let your landlord know through your tenant portal.' || chr(10);
  end if;
  if v_lines = '' then return null; end if;

  -- Only tenant-filed repairs
  if r.user_id is not null and (
       exists (select 1 from public.company_members m where m.company_id = r.company_id and m.user_id = r.user_id)
    or exists (select 1 from public.companies c where c.id = r.company_id and c.owner_user_id = r.user_id)) then
    return null;
  end if;

  -- Tenant on a current lease with this company (and property), recipient from the records
  select true, l.tenant_id, l.tenant_email, l.property_id
    into v_found, v_tenant, v_lease_em, v_lease_pr
    from public.leases l
   where l.company_id = r.company_id and l.archived_at is null and coalesce(l.status, '') <> 'ended'
     and (case when r.tenant_id is not null then l.tenant_id = r.tenant_id
               else r.tenant_email is not null and lower(l.tenant_email) = lower(btrim(r.tenant_email)) end)
     and (r.property_id is null or l.property_id is null or l.property_id = r.property_id)
   order by (l.property_id is not distinct from r.property_id) desc, l.lease_start desc nulls last
   limit 1;
  if not coalesce(v_found, false) then return null; end if;
  select nullif(btrim(t.email), '') into v_email from public.tenants t where t.id = v_tenant;
  v_email := coalesce(v_email, nullif(btrim(v_lease_em), ''));
  if v_email is null or v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then return null; end if;
  v_prop := coalesce(r.property_id, v_lease_pr);

  select coalesce((u.raw_user_meta_data -> 'notifications' ->> 'tenantRepairUpdates')::boolean, true) into v_on
    from public.companies c join auth.users u on u.id = c.owner_user_id where c.id = r.company_id;
  v_on := coalesce(v_on, true);

  v_key := 'repair_update:' || r.id || ':' || md5(coalesce(r.status, '') || '|' || coalesce(r.scheduled_at::text, '') || '|' || coalesce(btrim(r.assigned_vendor), ''));
  v_subject := case when v_done then 'Your repair is complete' else 'Update on your repair request' end
               || coalesce(' at ' || nullif(r.property_name, ''), '');
  v_body := 'Hi,' || chr(10) || chr(10)
            || 'There''s an update on your repair request' || coalesce(' at ' || nullif(r.property_name, ''), '') || ':' || chr(10) || chr(10)
            || v_lines || chr(10)
            || 'Your request: "' || left(coalesce(r.issue_description, ''), 300) || '"' || chr(10) || chr(10)
            || 'See it in your tenant portal:' || chr(10) || 'https://rentalgenieai.com/tenant-repair-requests.html' || chr(10) || chr(10)
            || '— Your landlord';

  insert into public.notifications (company_id, event_key, kind, channel, maintenance_request_id,
                                    property_id, tenant_id, recipient, subject, body, status, last_error)
  values (r.company_id, v_key, 'repair_update', 'email', r.id, v_prop, v_tenant, v_email, v_subject, v_body,
          case when v_on then 'queued' else 'skipped' end,
          case when v_on then null else 'Turned off in Account > Notifications' end)
  on conflict on constraint notifications_event_channel_key do nothing
  returning id into v_id;
  if v_id is null or not v_on then return null; end if;

  insert into public.tenant_messages (company_id, property_id, property_name, tenant_email, tenant_id, subject, message, sender)
  values (r.company_id, v_prop, r.property_name, v_email, v_tenant, v_subject, v_body, 'landlord');

  return v_id;
end;
$$;

create or replace function public.trigger_repair_update()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id bigint;
begin
  begin
    v_id := public.rg_repair_update_prepare(old, new);
    if v_id is not null then
      perform public.rg_notification_kick(v_id);
    end if;
  exception when others then
    raise warning 'repair update for request % not prepared: %', new.id, sqlerrm;
  end;
  return new;
end;
$$;

create trigger trg_repair_update
  after update of status, scheduled_at, assigned_vendor on public.maintenance_requests
  for each row execute function public.trigger_repair_update();

revoke execute on function public.rg_repair_update_prepare(public.maintenance_requests, public.maintenance_requests) from public, anon, authenticated;
revoke execute on function public.trigger_repair_update() from public, anon, authenticated;
