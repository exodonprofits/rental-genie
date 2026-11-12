-- rg_29: recording online payments (docs/design/stripe-online-rent.md, sections 4–7). Called only by the
-- Stripe Edge Functions with the service role; nothing here talks to Stripe.
--
-- Each state change is one function that locks the online_payments row first, so a webhook delivered twice
-- or out of order can't record rent twice:
--   rg_online_payment_processing(id, intent, session)  created -> processing (Checkout finished; ACH pending)
--   rg_online_payment_succeeded(id, intent, paid_on)   -> succeeded; rent recorded through rg_apply_payment
--                                                        (oldest unpaid month first, source 'stripe');
--                                                        landlord alert + tenant receipt. Only here is rent recorded.
--   rg_online_payment_failed(id, reason)               created/processing -> failed; both told
--   rg_online_payment_expired(id)                      created -> expired (Checkout abandoned)
--   rg_online_payment_reversed(id, status, reason)     succeeded -> refunded/disputed; the rent rows are archived
--                                                        (kept for history) so the balance comes back; landlord told
-- rg_my_online_pay_options(): for the signed-in tenant, which of their leases can be paid online now
-- (company's Stripe account can take charges, lease's pay_accepts_online on). The tenant pages use it to
-- show the Pay online button; the checkout function checks it again.
--
-- Emails go through the rg_17 outbox: landlord 'payment_received:<id>' / 'payment_failed:<id>' /
-- 'payment_reversed:<id>' (owner switch onlinePayments, missing = on); tenant 'payment_receipt:<id>' /
-- 'payment_failed_tenant:<id>' to the lease's tenant email.

create or replace function public.rg_online_payment_tenant_email(p public.online_payments, p_kind text, p_key text,
                                                                 p_subject text, p_body text)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_email text;
  v_id    bigint;
begin
  select coalesce(nullif(btrim(t.email), ''), nullif(btrim(l.tenant_email), ''), nullif(btrim(p.tenant_email), ''))
    into v_email
    from (select 1) x
    left join public.leases l on l.id = p.lease_id
    left join public.tenants t on t.id = coalesce(p.tenant_id, l.tenant_id);
  if v_email is null or v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    return null;
  end if;
  insert into public.notifications (company_id, event_key, kind, channel, property_id, tenant_id, recipient, subject, body, status)
  values (p.company_id, p_key, p_kind, 'email', p.property_id, p.tenant_id, v_email, left(p_subject, 200), p_body, 'queued')
  on conflict on constraint notifications_event_channel_key do nothing
  returning id into v_id;
  if v_id is not null then perform public.rg_notification_kick(v_id); end if;
  return v_id;
end;
$$;

create or replace function public.rg_online_payment_processing(p_id uuid, p_intent text default null, p_session text default null)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare p public.online_payments;
begin
  select * into p from public.online_payments where id = p_id for update;
  if not found then return 'not_found'; end if;
  update public.online_payments
     set status = case when status = 'created' then 'processing' else status end,
         stripe_payment_intent_id = coalesce(stripe_payment_intent_id, p_intent),
         stripe_checkout_session_id = coalesce(stripe_checkout_session_id, p_session),
         updated_at = now()
   where id = p_id;
  return (select status from public.online_payments where id = p_id);
end;
$$;

create or replace function public.rg_online_payment_succeeded(p_id uuid, p_intent text default null,
                                                              p_paid_on date default (now() at time zone 'America/Chicago')::date)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  p      public.online_payments;
  v_ids  uuid[];
  v_prop text;
  v_id   bigint;
begin
  select * into p from public.online_payments where id = p_id for update;
  if not found then return jsonb_build_object('status', 'not_found'); end if;
  if p.status in ('succeeded', 'refunded', 'disputed') then
    return jsonb_build_object('status', p.status, 'already', true);
  end if;

  v_ids := public.rg_apply_payment(p.company_id, p.property_id, p.amount, p_paid_on, 'Online (ACH)',
                                   'Paid online', 'stripe', null, null, null, p.id);
  update public.online_payments
     set status = 'succeeded', paid_at = now(), rent_log_ids = v_ids, failure_reason = null,
         stripe_payment_intent_id = coalesce(stripe_payment_intent_id, p_intent), updated_at = now()
   where id = p.id;

  select coalesce(nullif(pr.name, ''), 'your rental') into v_prop from public.properties pr where pr.id = p.property_id;
  begin
    v_id := public.rg_landlord_alert_prepare('payment_received', p.company_id, 'payment_received:' || p.id, 'onlinePayments',
      'Rent received online: ' || public.rg_money(p.amount) || ' for ' || v_prop,
      'An online rent payment of ' || public.rg_money(p.amount) || ' for ' || v_prop || ' has cleared.' || chr(10) || chr(10)
        || 'It is recorded in your rent ledger (oldest unpaid month first). Stripe pays it out to your bank account '
        || 'on its usual schedule.' || chr(10) || chr(10)
        || 'https://rentalgenieai.com/lease-rent-center.html?property_id=' || p.property_id || chr(10) || chr(10)
        || '— Rental Genie' || chr(10) || 'Turn these emails off in Account > Notifications.',
      null, p.property_id, p.tenant_id);
    if v_id is not null then perform public.rg_notification_kick(v_id); end if;
    perform public.rg_online_payment_tenant_email(p, 'payment_receipt', 'payment_receipt:' || p.id,
      'Payment received: ' || public.rg_money(p.amount) || ' rent for ' || v_prop,
      'Your rent payment of ' || public.rg_money(p.amount) || ' for ' || v_prop || ' has cleared. Thank you.' || chr(10) || chr(10)
        || 'See it in your payment history:' || chr(10) || 'https://rentalgenieai.com/tenant-payments.html' || chr(10) || chr(10)
        || '— Rental Genie, on behalf of your landlord');
  exception when others then
    raise warning 'online payment % emails not queued: %', p.id, sqlerrm;
  end;
  return jsonb_build_object('status', 'succeeded', 'rent_log_ids', to_jsonb(v_ids));
end;
$$;

create or replace function public.rg_online_payment_failed(p_id uuid, p_reason text default null)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  p      public.online_payments;
  v_prop text;
  v_id   bigint;
begin
  select * into p from public.online_payments where id = p_id for update;
  if not found then return 'not_found'; end if;
  if p.status not in ('created', 'processing') then return p.status; end if;
  update public.online_payments
     set status = 'failed', failure_reason = left(coalesce(nullif(btrim(p_reason), ''), 'The bank declined the payment.'), 500),
         updated_at = now()
   where id = p.id;

  select coalesce(nullif(pr.name, ''), 'your rental') into v_prop from public.properties pr where pr.id = p.property_id;
  begin
    perform public.rg_online_payment_tenant_email(p, 'payment_failed', 'payment_failed_tenant:' || p.id,
      'Your rent payment didn''t go through',
      'Your online rent payment of ' || public.rg_money(p.amount) || ' for ' || v_prop || ' didn''t go through'
        || coalesce(': ' || nullif(btrim(p_reason), ''), '.') || chr(10) || chr(10)
        || 'Nothing was recorded, and you can try again from your Payments page:' || chr(10)
        || 'https://rentalgenieai.com/tenant-payments.html' || chr(10) || chr(10)
        || '— Rental Genie, on behalf of your landlord');
    v_id := public.rg_landlord_alert_prepare('payment_failed', p.company_id, 'payment_failed:' || p.id, 'onlinePayments',
      'Online rent payment failed: ' || public.rg_money(p.amount) || ' for ' || v_prop,
      'An online rent payment of ' || public.rg_money(p.amount) || ' for ' || v_prop || ' failed'
        || coalesce(': ' || nullif(btrim(p_reason), ''), '.') || chr(10) || chr(10)
        || 'Nothing was recorded in your ledger. The tenant has been told and can try again.' || chr(10) || chr(10)
        || '— Rental Genie' || chr(10) || 'Turn these emails off in Account > Notifications.',
      null, p.property_id, p.tenant_id);
    if v_id is not null then perform public.rg_notification_kick(v_id); end if;
  exception when others then
    raise warning 'online payment % failure emails not queued: %', p.id, sqlerrm;
  end;
  return 'failed';
end;
$$;

create or replace function public.rg_online_payment_expired(p_id uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.online_payments set status = 'expired', updated_at = now()
   where id = p_id and status = 'created';
  return coalesce((select status from public.online_payments where id = p_id), 'not_found');
end;
$$;

create or replace function public.rg_online_payment_reversed(p_id uuid, p_status text, p_reason text default null)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  p      public.online_payments;
  v_prop text;
  v_id   bigint;
begin
  if p_status not in ('refunded', 'disputed') then
    raise exception 'p_status must be refunded or disputed' using errcode = '22023';
  end if;
  select * into p from public.online_payments where id = p_id for update;
  if not found then return 'not_found'; end if;
  if p.status <> 'succeeded' then return p.status; end if;

  update public.rent_log set archived_at = now()
   where id = any(p.rent_log_ids) and archived_at is null;
  update public.online_payments
     set status = p_status, failure_reason = left(coalesce(nullif(btrim(p_reason), ''), p_status), 500), updated_at = now()
   where id = p.id;

  select coalesce(nullif(pr.name, ''), 'your rental') into v_prop from public.properties pr where pr.id = p.property_id;
  begin
    v_id := public.rg_landlord_alert_prepare('payment_failed', p.company_id, 'payment_reversed:' || p.id, 'onlinePayments',
      case p_status when 'disputed' then 'Online rent payment disputed: ' else 'Online rent payment refunded: ' end
        || public.rg_money(p.amount) || ' for ' || v_prop,
      'The online rent payment of ' || public.rg_money(p.amount) || ' for ' || v_prop || ' was '
        || case p_status when 'disputed' then 'disputed or returned by the tenant''s bank' else 'refunded' end
        || coalesce(' (' || nullif(btrim(p_reason), '') || ')', '') || '.' || chr(10) || chr(10)
        || 'The rent it covered is back on the balance: its ledger entries were archived (still listed under archived). '
        || 'Stripe takes the amount back from your Stripe balance. Review it in Stripe and in Rental Genie:' || chr(10)
        || 'https://rentalgenieai.com/lease-rent-center.html?property_id=' || p.property_id || chr(10) || chr(10)
        || '— Rental Genie' || chr(10) || 'Turn these emails off in Account > Notifications.',
      null, p.property_id, p.tenant_id);
    if v_id is not null then perform public.rg_notification_kick(v_id); end if;
  exception when others then
    raise warning 'online payment % reversal email not queued: %', p.id, sqlerrm;
  end;
  return p_status;
end;
$$;

-- For the signed-in tenant: which of their leases can be paid online right now
create or replace function public.rg_my_online_pay_options()
returns table (lease_id uuid, company_id uuid, property_id uuid, property_name text, can_pay_online boolean)
language sql
stable
security definer
set search_path = 'public'
set row_security = off
as $$
  select l.id, l.company_id, l.property_id, l.property_name,
         (c.stripe_charges_enabled and c.stripe_account_id is not null and l.pay_accepts_online
          and c.archived_at is null) as can_pay_online
    from public.leases l
    join public.companies c on c.id = l.company_id
   where l.archived_at is null
     and (l.tenant_id = public.rg_tenant_id_for_auth_user()
          or (public.rg_auth_email() is not null and lower(l.tenant_email) = public.rg_auth_email()));
$$;

revoke execute on function public.rg_online_payment_tenant_email(public.online_payments, text, text, text, text) from public, anon, authenticated;
revoke execute on function public.rg_online_payment_processing(uuid, text, text) from public, anon, authenticated;
revoke execute on function public.rg_online_payment_succeeded(uuid, text, date) from public, anon, authenticated;
revoke execute on function public.rg_online_payment_failed(uuid, text) from public, anon, authenticated;
revoke execute on function public.rg_online_payment_expired(uuid) from public, anon, authenticated;
revoke execute on function public.rg_online_payment_reversed(uuid, text, text) from public, anon, authenticated;
grant execute on function public.rg_online_payment_processing(uuid, text, text) to service_role;
grant execute on function public.rg_online_payment_succeeded(uuid, text, date) to service_role;
grant execute on function public.rg_online_payment_failed(uuid, text) to service_role;
grant execute on function public.rg_online_payment_expired(uuid) to service_role;
grant execute on function public.rg_online_payment_reversed(uuid, text, text) to service_role;
revoke execute on function public.rg_my_online_pay_options() from public, anon;
grant execute on function public.rg_my_online_pay_options() to authenticated;
