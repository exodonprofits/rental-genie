-- rg_27: listings and applications review (the public, signed-out part of the app).
--
-- 1. public_listings could be written through. It is a plain view over properties owned by postgres
--    (BYPASSRLS) without security_invoker, so it reads past row-level security on purpose (anon must
--    see listed properties). But authenticated also had INSERT / UPDATE / DELETE on it, and a simple
--    view is auto-updatable: any signed-in user (anyone can sign up) could rewrite any listed
--    property's rent, description, contact email/phone and application link, or delete the property,
--    past properties_no_hard_delete. Confirmed in a rolled-back test on 2026-11-11 (a stranger's
--    UPDATE changed listing_rent). No property was listed at the time. Fix: the view is read-only for
--    everyone, and archived properties never show (it didn't filter archived_at).
--
-- 2. Applications and their messages were visible only to properties.owner_id, not to the company's
--    other members, unlike every other table (rg_can_access_property). Same rule now.
--
-- 3. claim_my_applications() linked applications to any signed-in account with the same email, without
--    checking that the email was confirmed. It now requires a confirmed email, like rg_claim_tenant_row.
--
-- 4. The public form had no limits: the same person could submit the same application repeatedly and
--    a script could flood a listing. A before-insert check now trims the fields, requires a valid
--    email, caps field lengths, rejects a second application for the same listing and email within
--    24 hours, and more than 30 applications to one listing in an hour.
--
-- 5. New applications reached the landlord only if they happened to open the listing page. A landlord
--    alert ('landlord_application:<id>', owner switch 'applications', missing = on) now goes through
--    the rg_17 outbox like repairs and messages; so does an applicant's reply
--    ('landlord_application:msg:<msg id>', same switch). Applicants get an email when the landlord messages
--    them or approves / denies the application ('applicant_message:<msg id>',
--    'applicant_status:<app id>:<status>'): only landlord actions send to the address an applicant
--    typed, so the public form can't be used to email arbitrary people.

-- 1 ─────────────────────────────────────────────────────────────────────────────────────────────
create or replace view public.public_listings as
select id, name, address, property_type, units, bedrooms, bathrooms, square_feet, year_built,
       listing_rent, listing_deposit, listing_available_date, listing_description, listing_photos,
       listing_pet_policy, listing_contact_email, listing_contact_phone, listing_published_at,
       listing_application_mode, listing_application_url
  from public.properties p
 where is_public_listing = true and archived_at is null;

comment on view public.public_listings is
  'Public columns of listed, non-archived properties. Runs as its owner on purpose (anon reads it); read-only: grant SELECT only, never write privileges.';

revoke all on public.public_listings from public, anon, authenticated;
grant select on public.public_listings to anon, authenticated;

-- 2 ─────────────────────────────────────────────────────────────────────────────────────────────
alter policy applications_select on public.applications
  using (applicant_user_id = (select auth.uid()) or public.rg_can_access_property(property_id));

alter policy "landlords update their applications" on public.applications
  using (public.rg_can_access_property(property_id))
  with check (public.rg_can_access_property(property_id));

alter policy application_messages_select on public.application_messages
  using (application_id in (select a.id from public.applications a
                             where a.applicant_user_id = (select auth.uid())
                                or public.rg_can_access_property(a.property_id)));

alter policy application_messages_insert on public.application_messages
  with check (
    (sender_role = 'applicant' and application_id in (select a.id from public.applications a
                                                       where a.applicant_user_id = (select auth.uid())))
    or (sender_role = 'landlord' and application_id in (select a.id from public.applications a
                                                         where public.rg_can_access_property(a.property_id))));

-- 3 ─────────────────────────────────────────────────────────────────────────────────────────────
create or replace function public.claim_my_applications()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  my_email text;
  claimed_count int;
begin
  select u.email into my_email from auth.users u
   where u.id = auth.uid() and u.email_confirmed_at is not null;
  if my_email is null then
    return 0;
  end if;

  update public.applications
     set applicant_user_id = auth.uid()
   where applicant_user_id is null
     and lower(applicant_email) = lower(my_email);

  get diagnostics claimed_count = row_count;
  return claimed_count;
end;
$$;

revoke execute on function public.claim_my_applications() from public, anon;
grant execute on function public.claim_my_applications() to authenticated;

-- 4 ─────────────────────────────────────────────────────────────────────────────────────────────
create or replace function public.trigger_application_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  new.applicant_name  := btrim(coalesce(new.applicant_name, ''));
  new.applicant_email := lower(btrim(coalesce(new.applicant_email, '')));

  if new.applicant_name = '' then
    raise exception 'Please enter your name.' using errcode = '22023';
  end if;
  if new.applicant_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'Please enter a valid email address.' using errcode = '22023';
  end if;
  if length(new.applicant_name) > 200 or length(new.applicant_email) > 254
     or length(coalesce(new.applicant_phone, '')) > 40 or length(coalesce(new.current_address, '')) > 500
     or length(coalesce(new.employer_name, '')) > 200 or length(coalesce(new.pet_details, '')) > 1000
     or length(coalesce(new.emergency_contact_name, '')) > 200 or length(coalesce(new.emergency_contact_phone, '')) > 40
     or length(coalesce(new.message, '')) > 5000 or length(coalesce(new.property_name, '')) > 300
     or length(coalesce(new.property_address, '')) > 500 then
    raise exception 'Some answers are too long. Please shorten them and try again.' using errcode = '22001';
  end if;

  if exists (select 1 from public.applications a
              where a.property_id = new.property_id and lower(a.applicant_email) = new.applicant_email
                and a.created_at > now() - interval '24 hours') then
    raise exception 'You already applied for this rental today. The landlord has your application.' using errcode = '23505';
  end if;
  if (select count(*) from public.applications a
       where a.property_id = new.property_id and a.created_at > now() - interval '1 hour') >= 30 then
    raise exception 'This listing is receiving a lot of applications. Please try again in an hour.' using errcode = '54000';
  end if;
  return new;
end;
$$;

create trigger trg_application_guard
  before insert on public.applications
  for each row execute function public.trigger_application_guard();

-- 5 ─────────────────────────────────────────────────────────────────────────────────────────────
insert into public.notification_kinds (kind, description) values
  ('landlord_application', 'Landlord: a renter applied to a listing'),
  ('applicant_update',     'Applicant: landlord message or decision on their application')
on conflict (kind) do nothing;

-- Landlord: new application
create or replace function public.trigger_application_alert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company uuid;
  v_prop    text;
  v_id      bigint;
begin
  begin
    select p.company_id, coalesce(nullif(p.name, ''), new.property_name, 'your listing')
      into v_company, v_prop
      from public.properties p where p.id = new.property_id;
    if v_company is null then return new; end if;
    v_id := public.rg_landlord_alert_prepare('landlord_application', v_company,
      'landlord_application:' || new.id, 'applications',
      'New application for ' || v_prop || ' from ' || new.applicant_name,
      new.applicant_name || ' applied for ' || v_prop || '.' || chr(10) || chr(10)
        || 'Email: ' || new.applicant_email || chr(10)
        || coalesce('Phone: ' || nullif(btrim(new.applicant_phone), '') || chr(10), '')
        || coalesce('Move-in: ' || to_char(new.desired_move_in, 'FMMon FMDD, YYYY') || chr(10), '')
        || coalesce('Monthly income: ' || public.rg_money(new.monthly_income) || chr(10), '')
        || coalesce('Occupants: ' || new.occupants_count || chr(10), '')
        || case when new.has_pets then 'Pets: ' || coalesce(nullif(btrim(new.pet_details), ''), 'yes') || chr(10) else '' end
        || case when new.screening_consent then 'Agreed to a background/credit check.' || chr(10) else '' end
        || coalesce(chr(10) || 'Message: "' || left(nullif(btrim(new.message), ''), 1000) || '"' || chr(10), '')
        || chr(10) || 'Review it and reply in Rental Genie:' || chr(10)
        || 'https://rentalgenieai.com/publish-listing.html?property_id=' || new.property_id || chr(10) || chr(10)
        || '— Rental Genie' || chr(10) || 'Turn these emails off in Account > Notifications.',
      null, new.property_id, null);
    if v_id is not null then perform public.rg_notification_kick(v_id); end if;
  exception when others then
    raise warning 'application alert for % not prepared: %', new.id, sqlerrm;
  end;
  return new;
end;
$$;

create trigger trg_application_alert
  after insert on public.applications
  for each row execute function public.trigger_application_alert();

-- Applicant: landlord message or decision. Only landlord actions reach here.
create or replace function public.rg_applicant_update_prepare(p_app uuid, p_key text, p_subject text, p_lines text)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  a      record;
  v_comp uuid;
  v_id   bigint;
begin
  select ap.*, p.company_id as comp, coalesce(nullif(p.name, ''), ap.property_name, 'the rental') as prop
    into a
    from public.applications ap join public.properties p on p.id = ap.property_id
   where ap.id = p_app;
  if a.id is null or a.comp is null or a.applicant_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    return null;
  end if;

  insert into public.notifications (company_id, event_key, kind, channel, property_id, recipient, subject, body, status)
  values (a.comp, p_key, 'applicant_update', 'email', a.property_id, a.applicant_email,
          left(p_subject || ' — ' || a.prop, 200),
          'Hi ' || split_part(a.applicant_name, ' ', 1) || ',' || chr(10) || chr(10)
            || p_lines || chr(10) || chr(10)
            || 'See your application and reply to the landlord (sign in with this email address):' || chr(10)
            || 'https://rentalgenieai.com/login.html?role=applicant' || chr(10) || chr(10)
            || '— Sent by Rental Genie for the landlord of ' || a.prop,
          'queued')
  on conflict on constraint notifications_event_channel_key do nothing
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.trigger_applicant_message_email()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id   bigint;
  a      record;
begin
  if new.sender_role = 'applicant' then
    -- The applicant replied: tell the landlord (same switch as new applications)
    begin
      select ap.applicant_name, ap.property_id, p.company_id,
             coalesce(nullif(p.name, ''), ap.property_name, 'your listing') as prop
        into a
        from public.applications ap join public.properties p on p.id = ap.property_id
       where ap.id = new.application_id;
      if a.company_id is not null then
        v_id := public.rg_landlord_alert_prepare('landlord_application', a.company_id,
          'landlord_application:msg:' || new.id, 'applications',
          'New message from applicant ' || a.applicant_name || ' (' || a.prop || ')',
          a.applicant_name || ', who applied for ' || a.prop || ', sent you a message:' || chr(10) || chr(10)
            || '"' || left(coalesce(new.message, ''), 2000) || '"' || chr(10) || chr(10)
            || 'Reply in Rental Genie:' || chr(10)
            || 'https://rentalgenieai.com/publish-listing.html?property_id=' || a.property_id || chr(10) || chr(10)
            || '— Rental Genie' || chr(10) || 'Turn these emails off in Account > Notifications.',
          null, a.property_id, null);
        if v_id is not null then perform public.rg_notification_kick(v_id); end if;
      end if;
    exception when others then
      raise warning 'landlord alert for applicant message % not prepared: %', new.id, sqlerrm;
    end;
    return new;
  end if;
  if new.sender_role <> 'landlord' then return new; end if;
  begin
    v_id := public.rg_applicant_update_prepare(new.application_id, 'applicant_message:' || new.id,
      'New message about your application',
      'The landlord sent you a message about your rental application:' || chr(10) || chr(10)
        || '"' || left(coalesce(new.message, ''), 2000) || '"');
    if v_id is not null then perform public.rg_notification_kick(v_id); end if;
  exception when others then
    raise warning 'applicant email for message % not prepared: %', new.id, sqlerrm;
  end;
  return new;
end;
$$;

create trigger trg_applicant_message_email
  after insert on public.application_messages
  for each row execute function public.trigger_applicant_message_email();

create or replace function public.trigger_applicant_status_email()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare v_id bigint;
begin
  if new.status is not distinct from old.status or new.status not in ('approved', 'denied') then
    return new;
  end if;
  begin
    v_id := public.rg_applicant_update_prepare(new.id, 'applicant_status:' || new.id || ':' || new.status,
      case new.status when 'approved' then 'Your application was approved' else 'Update on your application' end,
      case new.status
        when 'approved' then 'Good news: the landlord approved your application. They''ll be in touch about next steps (lease and move-in).'
        else 'The landlord has decided not to move forward with your application. Thank you for applying.' end);
    if v_id is not null then perform public.rg_notification_kick(v_id); end if;
  exception when others then
    raise warning 'applicant status email for % not prepared: %', new.id, sqlerrm;
  end;
  return new;
end;
$$;

create trigger trg_applicant_status_email
  after update of status on public.applications
  for each row execute function public.trigger_applicant_status_email();

revoke execute on function public.trigger_application_guard() from public, anon, authenticated;
revoke execute on function public.trigger_application_alert() from public, anon, authenticated;
revoke execute on function public.rg_applicant_update_prepare(uuid, text, text, text) from public, anon, authenticated;
revoke execute on function public.trigger_applicant_message_email() from public, anon, authenticated;
revoke execute on function public.trigger_applicant_status_email() from public, anon, authenticated;
