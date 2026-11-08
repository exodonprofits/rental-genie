-- rg_21: email the landlord when a tenant files a repair or sends a message.
--
-- Same outbox as rg_17: one notifications row per event under a unique key
-- ('landlord_repair:<request id>', 'landlord_message:<message id>'), delivered by the
-- maintenance-acknowledgment Edge Function (which sends whatever is queued) with retries from the
-- rg-notification-sweep cron job. Failures show on the dashboard.
--
-- Recipient: the company owner's sign-in email (companies.owner_user_id -> auth.users). Preferences:
-- the owner's Account > Notifications switches, saved in their user metadata as
-- notifications.maintenance and notifications.messages; missing means on. A switched-off alert is
-- recorded as 'skipped' so the log still shows it happened.
-- Only tenant-originated events alert: a repair logged by a company member, and messages with
-- sender <> 'tenant' (including the automatic acknowledgment), don't. Errors are caught, so an alert
-- problem never blocks filing a repair or sending a message.

create or replace function public.rg_url_part(p text)
returns text
language sql
immutable
set search_path = ''
as $$
  select replace(replace(replace(replace(replace(coalesce(p, ''), '%', '%25'), ' ', '%20'), '&', '%26'), '#', '%23'), '?', '%3F');
$$;

-- Queue (or record as skipped) one landlord alert. Returns the queued notification id, or null.
create or replace function public.rg_landlord_alert_prepare(
  p_kind text, p_company uuid, p_key text, p_pref text, p_subject text, p_body text,
  p_maint_id integer default null, p_property uuid default null, p_tenant uuid default null)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_email text;
  v_on    boolean;
  v_id    bigint;
begin
  select u.email, coalesce((u.raw_user_meta_data -> 'notifications' ->> p_pref)::boolean, true)
    into v_email, v_on
    from public.companies c join auth.users u on u.id = c.owner_user_id
   where c.id = p_company;

  insert into public.notifications (company_id, event_key, kind, channel, maintenance_request_id,
                                    property_id, tenant_id, recipient, subject, body, status, last_error)
  values (p_company, p_key, p_kind, 'email', p_maint_id, p_property, p_tenant, v_email,
          left(p_subject, 200), p_body,
          case when v_email is null or not v_on then 'skipped' else 'queued' end,
          case when v_email is null then 'No email for the company owner'
               when not v_on then 'Turned off in Account > Notifications' end)
  on conflict on constraint notifications_event_channel_key do nothing
  returning id into v_id;

  if v_id is null or v_email is null or not v_on then
    return null;
  end if;
  return v_id;
end;
$$;

create or replace function public.rg_landlord_repair_alert(r public.maintenance_requests)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant  text;
  v_urgent  boolean := lower(coalesce(r.urgency_level, '')) in ('high', 'emergency');
  v_subject text;
  v_body    text;
begin
  if r.user_id is not null and (
       exists (select 1 from public.company_members m where m.company_id = r.company_id and m.user_id = r.user_id)
    or exists (select 1 from public.companies c where c.id = r.company_id and c.owner_user_id = r.user_id)) then
    return null;
  end if;

  select nullif(btrim(t.tenant_name), '') into v_tenant from public.tenants t where t.id = r.tenant_id;
  v_subject := case when v_urgent then 'URGENT: ' else '' end || 'New repair request'
               || coalesce(' at ' || nullif(r.property_name, ''), '');
  v_body := coalesce(v_tenant, 'A tenant') || ' filed a repair request'
            || coalesce(' for ' || nullif(r.property_name, ''), '') || '.' || chr(10) || chr(10)
            || 'Urgency: ' || coalesce(nullif(r.urgency_level, ''), 'Normal') || chr(10) || chr(10)
            || '"' || left(coalesce(r.issue_description, ''), 2000) || '"' || chr(10) || chr(10)
            || 'Open it in Rental Genie:' || chr(10)
            || 'https://rentalgenieai.com/maintenance-requests.html'
            || coalesce('?property=' || public.rg_url_part(nullif(r.property_name, '')), '') || chr(10) || chr(10)
            || case when v_urgent then 'The tenant marked this ' || lower(r.urgency_level) || '. Rental Genie doesn''t dispatch anyone, so contact them or your vendor directly.' || chr(10) || chr(10) else '' end
            || '— Rental Genie' || chr(10)
            || 'Turn these emails off in Account > Notifications.';
  return public.rg_landlord_alert_prepare('landlord_repair', r.company_id, 'landlord_repair:' || r.id,
                                          'maintenance', v_subject, v_body, r.id, r.property_id, r.tenant_id);
end;
$$;

create or replace function public.rg_landlord_message_alert(m public.tenant_messages)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant  text;
  v_subject text;
  v_body    text;
begin
  if coalesce(m.sender, '') <> 'tenant' or m.company_id is null then
    return null;
  end if;
  select nullif(btrim(t.tenant_name), '') into v_tenant from public.tenants t where t.id = m.tenant_id;
  v_subject := 'New message from ' || coalesce(v_tenant, m.tenant_email, 'a tenant')
               || coalesce(': ' || nullif(btrim(m.subject), ''), '');
  v_body := coalesce(v_tenant, m.tenant_email, 'A tenant')
            || coalesce(' (' || nullif(m.property_name, '') || ')', '') || ' sent you a message.' || chr(10) || chr(10)
            || coalesce('Subject: ' || nullif(btrim(m.subject), '') || chr(10) || chr(10), '')
            || left(coalesce(m.message, ''), 2000) || chr(10) || chr(10)
            || 'Reply in Rental Genie:' || chr(10)
            || 'https://rentalgenieai.com/tenant-messages.html'
            || coalesce('?property=' || public.rg_url_part(nullif(m.property_name, '')), '') || chr(10) || chr(10)
            || '— Rental Genie' || chr(10)
            || 'Turn these emails off in Account > Notifications.';
  return public.rg_landlord_alert_prepare('landlord_message', m.company_id, 'landlord_message:' || m.id,
                                          'messages', v_subject, v_body, null, m.property_id, m.tenant_id);
end;
$$;

-- Repairs: acknowledgment to the tenant (rg_17) and alert to the landlord, each in its own guard
create or replace function public.trigger_maintenance_acknowledgment()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_res jsonb;
  v_id  bigint;
begin
  begin
    v_res := public.rg_maint_ack_prepare(new);
    if v_res ->> 'action' = 'send' then
      perform public.rg_notification_kick((v_res ->> 'notification_id')::bigint);
    end if;
  exception when others then
    raise warning 'maintenance acknowledgment for request % not prepared: %', new.id, sqlerrm;
  end;
  begin
    v_id := public.rg_landlord_repair_alert(new);
    if v_id is not null then
      perform public.rg_notification_kick(v_id);
    end if;
  exception when others then
    raise warning 'landlord alert for request % not prepared: %', new.id, sqlerrm;
  end;
  return new;
end;
$$;

create or replace function public.trigger_tenant_message_alert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id bigint;
begin
  begin
    v_id := public.rg_landlord_message_alert(new);
    if v_id is not null then
      perform public.rg_notification_kick(v_id);
    end if;
  exception when others then
    raise warning 'landlord alert for message % not prepared: %', new.id, sqlerrm;
  end;
  return new;
end;
$$;

create trigger trg_tenant_message_alert
  after insert on public.tenant_messages
  for each row execute function public.trigger_tenant_message_alert();

revoke execute on function public.rg_url_part(text) from public, anon, authenticated;
revoke execute on function public.rg_landlord_alert_prepare(text, uuid, text, text, text, text, integer, uuid, uuid) from public, anon, authenticated;
revoke execute on function public.rg_landlord_repair_alert(public.maintenance_requests) from public, anon, authenticated;
revoke execute on function public.rg_landlord_message_alert(public.tenant_messages) from public, anon, authenticated;
revoke execute on function public.trigger_tenant_message_alert() from public, anon, authenticated;
revoke execute on function public.trigger_maintenance_acknowledgment() from public, anon, authenticated;
