-- rg_17: notification log (outbox) and a dependable maintenance acknowledgment.
--
-- Before: the maintenance_requests trigger posted the whole row to the maintenance-acknowledgment
-- Edge Function, which trusted the payload's tenant_email (after a lease lookup), wrote the in-app
-- message and sent the email with no record of either. A repeated call sent twice, a failed email
-- was invisible (HTTP 200 regardless), and a lost pg_net request lost the acknowledgment.
--
-- Now:
--   1. The trigger calls rg_maint_ack_prepare(new) inside the insert's transaction. It decides
--      whether an acknowledgment is owed, resolves the recipient from the lease and tenant records
--      (never from the request's tenant_email), writes the in-app message, and records one
--      notifications row per channel under a unique event key ('maint_ack:<request id>'), so the
--      same repair can never be acknowledged twice. Any error here is caught: a notification
--      problem never blocks filing a repair.
--   2. The trigger then asks the Edge Function to send the queued email ({notification_id} only).
--      The function claims the attempt (rg_notification_begin), sends through Resend with the event
--      key as its Idempotency-Key, and records the outcome (rg_notification_finish).
--   3. Temporary failures (network, 429, 5xx) are retried by rg_notification_sweep() from pg_cron
--      every 5 minutes with backoff (2 min, 10 min, 1 h, 6 h; 5 attempts). A request the trigger's
--      call never delivered is picked up the same way. Permanent failures (bad address, sender not
--      configured) stop at 'failed' and show on the landlord's dashboard until dismissed.
--
-- Landlords read their company's rows (RLS, rg_company_access) and can dismiss a failure through
-- rg_dismiss_notification(); nothing else is writable from the client. Service role and the
-- definer functions do the rest.

-- Foreign keys use the default (no action): companies, properties, tenants and repairs are
-- archived, never removed, so a log row can't be orphaned.
-- ── Table ────────────────────────────────────────────────────────────────────────────────────
create table if not exists public.notifications (
  id                     bigint generated always as identity primary key,
  company_id             uuid not null references public.companies (id),
  event_key              text not null,
  kind                   text not null check (kind in ('maintenance_ack')),
  channel                text not null check (channel in ('email', 'in_app')),
  maintenance_request_id integer,
  property_id            uuid references public.properties (id),
  tenant_id              uuid references public.tenants (id),
  recipient              text,
  subject                text,
  body                   text,
  status                 text not null default 'queued'
                         check (status in ('queued', 'sending', 'retry', 'sent', 'failed', 'skipped')),
  attempts               integer not null default 0,
  next_attempt_at        timestamptz,
  last_error             text,
  provider_message_id    text,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  sent_at                timestamptz,
  dismissed_at           timestamptz,
  dismissed_by           uuid,
  constraint notifications_event_channel_key unique (event_key, channel),
  constraint notifications_maintenance_request_fkey
    foreign key (maintenance_request_id, company_id)
    references public.maintenance_requests (id, company_id)
);

comment on table public.notifications is
  'Outbox and delivery log: one row per event and channel (unique event_key + channel). Written by definer functions and the maintenance-acknowledgment Edge Function only (rg_17).';

create index if not exists idx_notifications_company_status on public.notifications (company_id, status);
create index if not exists idx_notifications_due on public.notifications (status, next_attempt_at)
  where status in ('queued', 'sending', 'retry');
create index if not exists idx_notifications_maintenance_request on public.notifications (maintenance_request_id)
  where maintenance_request_id is not null;

alter table public.notifications enable row level security;

revoke all on public.notifications from anon, authenticated;
grant select on public.notifications to authenticated;

create policy notifications_select on public.notifications
  for select to authenticated
  using (public.rg_company_access(company_id));

-- ── Decide, resolve the recipient, write the in-app message, queue the email ─────────────────
create or replace function public.rg_maint_ack_prepare(r public.maintenance_requests)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_key      text := 'maint_ack:' || r.id;
  v_subject  text := 'We received your maintenance request';
  v_tenant   uuid;
  v_lease_em text;
  v_lease_pr uuid;
  v_found    boolean := false;
  v_email    text;
  v_reason   text;
  v_email_id bigint;
  v_app_id   bigint;
  v_intro    text;
  v_outro    text;
  v_prop     uuid;
begin
  if exists (select 1 from public.notifications where event_key = v_key) then
    return jsonb_build_object('action', 'duplicate');
  end if;

  -- Logged by the landlord or a company member: no acknowledgment
  if r.user_id is not null and (
       exists (select 1 from public.company_members m where m.company_id = r.company_id and m.user_id = r.user_id)
    or exists (select 1 from public.companies c where c.id = r.company_id and c.owner_user_id = r.user_id)) then
    v_reason := 'Logged by the landlord';
  else
    -- The tenant on a current lease with this company (and this property, when both are known).
    -- By tenant_id when the request has one; otherwise by the request's email against the lease.
    select true, l.tenant_id, l.tenant_email, l.property_id
      into v_found, v_tenant, v_lease_em, v_lease_pr
      from public.leases l
     where l.company_id = r.company_id
       and l.archived_at is null
       and coalesce(l.status, '') <> 'ended'
       and (case when r.tenant_id is not null then l.tenant_id = r.tenant_id
                 else r.tenant_email is not null and lower(l.tenant_email) = lower(btrim(r.tenant_email)) end)
       and (r.property_id is null or l.property_id is null or l.property_id = r.property_id)
     order by (l.property_id is not distinct from r.property_id) desc, l.lease_start desc nulls last
     limit 1;

    if not coalesce(v_found, false) then
      v_reason := 'Not filed by a tenant on a current lease with this company and property';
    else
      -- Recipient from the records: the tenant row's email, else the lease's
      select nullif(btrim(t.email), '') into v_email from public.tenants t where t.id = v_tenant;
      v_email := coalesce(v_email, nullif(btrim(v_lease_em), ''));
      if v_email is null or v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
        v_reason := 'No valid email on the tenant or lease record';
      end if;
    end if;
  end if;

  v_prop := coalesce(r.property_id, v_lease_pr);

  if v_reason is not null then
    insert into public.notifications (company_id, event_key, kind, channel, maintenance_request_id,
                                      property_id, tenant_id, recipient, subject, status, last_error)
    values (r.company_id, v_key, 'maintenance_ack', 'email', r.id, v_prop, v_tenant, v_email,
            v_subject, 'skipped', v_reason)
    on conflict on constraint notifications_event_channel_key do nothing;
    return jsonb_build_object('action', 'skip', 'reason', v_reason);
  end if;

  v_intro := 'Hi,' || chr(10) || chr(10) || 'We''ve received your maintenance request'
             || coalesce(' for ' || nullif(r.property_name, ''), '');
  v_outro := chr(10) || chr(10) || 'We''re on it and will follow up shortly with next steps.'
             || case when lower(coalesce(r.urgency_level, '')) in ('high', 'emergency')
                     then ' Given the urgency, we''re prioritizing this.' else '' end
             || chr(10) || chr(10) || '— Your landlord';

  -- Email first: the unique key makes a concurrent second call stop here
  insert into public.notifications (company_id, event_key, kind, channel, maintenance_request_id,
                                    property_id, tenant_id, recipient, subject, body, status)
  values (r.company_id, v_key, 'maintenance_ack', 'email', r.id, v_prop, v_tenant, v_email,
          v_subject, v_intro || '.' || v_outro, 'queued')
  on conflict on constraint notifications_event_channel_key do nothing
  returning id into v_email_id;

  if v_email_id is null then
    return jsonb_build_object('action', 'duplicate');
  end if;

  -- In-app message (quotes the request; the email doesn't)
  insert into public.notifications (company_id, event_key, kind, channel, maintenance_request_id,
                                    property_id, tenant_id, recipient, subject, status, attempts, sent_at)
  values (r.company_id, v_key, 'maintenance_ack', 'in_app', r.id, v_prop, v_tenant, v_email,
          v_subject, 'sent', 1, now())
  on conflict on constraint notifications_event_channel_key do nothing
  returning id into v_app_id;

  if v_app_id is not null then
    insert into public.tenant_messages (company_id, property_id, property_name, tenant_email, tenant_id,
                                        subject, message, sender)
    values (r.company_id, v_prop, r.property_name, v_email, v_tenant, v_subject,
            v_intro || coalesce(':' || chr(10) || chr(10) || '"' || nullif(r.issue_description, '') || '"', '.') || v_outro,
            'landlord');
  end if;

  return jsonb_build_object('action', 'send', 'notification_id', v_email_id);
end;
$$;

-- ── Ask the Edge Function to deliver one queued notification ─────────────────────────────────
create or replace function public.rg_notification_kick(p_id bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform net.http_post(
    url := 'https://xqmnaeujwumlcoyhgzuk.supabase.co/functions/v1/maintenance-acknowledgment',
    headers := jsonb_build_object('Content-Type', 'application/json',
                                  'x-webhook-secret', public.rg_maintenance_webhook_secret()),
    body := jsonb_build_object('notification_id', p_id)
  );
end;
$$;

-- ── Trigger: prepare inside the insert, then kick the sender. Never blocks the insert. ───────
create or replace function public.trigger_maintenance_acknowledgment()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_res jsonb;
begin
  begin
    v_res := public.rg_maint_ack_prepare(new);
    if v_res ->> 'action' = 'send' then
      perform public.rg_notification_kick((v_res ->> 'notification_id')::bigint);
    end if;
  exception when others then
    raise warning 'maintenance acknowledgment for request % not prepared: %', new.id, sqlerrm;
  end;
  return new;
end;
$$;

-- ── Claim one delivery attempt (the Edge Function calls this before sending) ─────────────────
create or replace function public.rg_notification_begin(p_id bigint)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  update public.notifications n
     set status = 'sending', attempts = n.attempts + 1, updated_at = now(), next_attempt_at = null
   where n.id = p_id
     and n.channel = 'email'
     and (   (n.status in ('queued', 'retry') and coalesce(n.next_attempt_at, now()) <= now())
          or (n.status = 'sending' and n.updated_at < now() - interval '15 minutes'))
  returning jsonb_build_object('id', n.id, 'event_key', n.event_key, 'recipient', n.recipient,
                               'subject', n.subject, 'body', n.body, 'attempts', n.attempts);
$$;

-- ── Record the outcome of an attempt ─────────────────────────────────────────────────────────
create or replace function public.rg_notification_finish(p_id bigint, p_ok boolean, p_error text default null,
                                                         p_provider_id text default null,
                                                         p_permanent boolean default false)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_attempts integer;
  v_status   text;
begin
  select attempts into v_attempts from public.notifications where id = p_id and status = 'sending' for update;
  if not found then
    return null;
  end if;

  if p_ok then
    v_status := 'sent';
    update public.notifications
       set status = v_status, sent_at = now(), updated_at = now(), last_error = null,
           provider_message_id = p_provider_id
     where id = p_id;
  elsif p_permanent or v_attempts >= 5 then
    v_status := 'failed';
    update public.notifications
       set status = v_status, updated_at = now(), next_attempt_at = null, last_error = left(p_error, 1000)
     where id = p_id;
  else
    v_status := 'retry';
    update public.notifications
       set status = v_status, updated_at = now(), last_error = left(p_error, 1000),
           next_attempt_at = now() + (array[interval '2 minutes', interval '10 minutes',
                                            interval '1 hour', interval '6 hours'])[v_attempts]
     where id = p_id;
  end if;
  return v_status;
end;
$$;

-- ── Retry sweep (pg_cron, every 5 minutes) ───────────────────────────────────────────────────
create or replace function public.rg_notification_sweep()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id bigint;
  v_n  integer := 0;
begin
  for v_id in
    select id from public.notifications
     where channel = 'email'
       and (   (status = 'queued'  and created_at < now() - interval '2 minutes')
            or (status = 'retry'   and next_attempt_at <= now())
            or (status = 'sending' and updated_at < now() - interval '15 minutes'))
     order by id
     limit 20
  loop
    perform public.rg_notification_kick(v_id);
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;

-- ── Landlord dismisses a failure they've dealt with ──────────────────────────────────────────
create or replace function public.rg_dismiss_notification(p_id bigint)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.notifications
     set dismissed_at = now(), dismissed_by = auth.uid(), updated_at = now()
   where id = p_id
     and status = 'failed'
     and dismissed_at is null
     and public.rg_company_access(company_id);
  return found;
end;
$$;

revoke execute on function public.rg_maint_ack_prepare(public.maintenance_requests) from public, anon, authenticated;
revoke execute on function public.rg_notification_kick(bigint) from public, anon, authenticated;
revoke execute on function public.trigger_maintenance_acknowledgment() from public, anon, authenticated;
revoke execute on function public.rg_notification_begin(bigint) from public, anon, authenticated;
revoke execute on function public.rg_notification_finish(bigint, boolean, text, text, boolean) from public, anon, authenticated;
revoke execute on function public.rg_notification_sweep() from public, anon, authenticated;
revoke execute on function public.rg_dismiss_notification(bigint) from public, anon;
grant execute on function public.rg_notification_begin(bigint) to service_role;
grant execute on function public.rg_notification_finish(bigint, boolean, text, text, boolean) to service_role;
grant execute on function public.rg_dismiss_notification(bigint) to authenticated;
