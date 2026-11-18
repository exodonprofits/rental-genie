-- rg_31: plans and the Free property limit, built switched off.
--
-- The homepage: Free is "up to 3 properties", Pro is unlimited, and "during early access, every account gets Pro
-- features at no charge". So:
--   - plan_limits      : what each plan allows (free: 3 active properties, pro: no limit). Only properties are limited.
--   - company_plans    : each company's own plan (no row = free). Written by the service role only, never by pages:
--                        companies lets signed-in users update its columns, so the plan can't live there.
--   - rg_settings      : 'early_access' (on). While on, every company's effective plan is pro.
-- Ending early access is one statement, no code:  update public.rg_settings set enabled = false where name = 'early_access';
--
-- Enforcement is in the database: a before trigger on properties refuses a new or restored active property past the
-- limit, whichever page or function sends it. Pages read their plan through rg_my_plan(company_id).

create table public.plan_limits (
  plan           text primary key check (plan in ('free', 'pro')),
  max_properties int  check (max_properties is null or max_properties > 0)   -- null = unlimited
);
insert into public.plan_limits (plan, max_properties) values ('free', 3), ('pro', null);

create table public.company_plans (
  company_id uuid primary key references public.companies(id),
  plan       text not null default 'free' references public.plan_limits(plan),
  note       text,
  updated_at timestamptz not null default now()
);

create table public.rg_settings (
  name       text primary key,
  enabled    boolean not null,
  note       text,
  updated_at timestamptz not null default now()
);
insert into public.rg_settings (name, enabled, note) values
  ('early_access', true, 'While on, every company gets Pro (no property limit). Turn off when early access ends.');

-- Read only through the functions below; no direct access for anon or signed-in users.
alter table public.plan_limits   enable row level security;
alter table public.company_plans enable row level security;
alter table public.rg_settings   enable row level security;
revoke all on public.plan_limits, public.company_plans, public.rg_settings from anon, authenticated;

-- The founder's company keeps Pro when early access ends.
insert into public.company_plans (company_id, plan, note)
select id, 'pro', 'Founder account' from public.companies where id = '6d341ed2-5376-419f-8566-655a9253ff06';

-- Effective plan and limit for a company (internal; no access check).
create or replace function public.rg_plan_for(p_company_id uuid)
returns table (plan text, effective_plan text, early_access boolean, max_properties int)
language sql stable security definer set search_path = '' as $$
  with s as (select coalesce((select enabled from public.rg_settings where name = 'early_access'), false) as ea),
       p as (select coalesce((select cp.plan from public.company_plans cp where cp.company_id = p_company_id), 'free') as plan)
  select p.plan,
         case when s.ea then 'pro' else p.plan end,
         s.ea,
         (select l.max_properties from public.plan_limits l where l.plan = case when s.ea then 'pro' else p.plan end)
  from s, p;
$$;
revoke all on function public.rg_plan_for(uuid) from public, anon, authenticated;

-- For pages: the caller's company plan and usage. Nothing for a company the caller can't access.
create or replace function public.rg_my_plan(p_company_id uuid)
returns table (plan text, effective_plan text, early_access boolean, max_properties int, active_properties int)
language plpgsql stable security definer set search_path = '' as $$
begin
  if p_company_id is null or not public.rg_company_access(p_company_id) then return; end if;
  return query
    select f.plan, f.effective_plan, f.early_access, f.max_properties,
           (select count(*)::int from public.properties pr where pr.company_id = p_company_id and pr.archived_at is null)
    from public.rg_plan_for(p_company_id) f;
end;
$$;
revoke all on function public.rg_my_plan(uuid) from public, anon;
grant execute on function public.rg_my_plan(uuid) to authenticated;

-- The limit: a property that becomes active (inserted, restored, or moved to another company) must fit the plan.
create or replace function public.rg_properties_plan_limit()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_max int; v_active int;
begin
  if new.archived_at is not null or new.company_id is null then return new; end if;
  if tg_op = 'UPDATE' and old.archived_at is null and old.company_id is not distinct from new.company_id then
    return new;   -- already counted
  end if;
  -- one property at a time per company, so two saves can't both slip under the limit
  perform 1 from public.companies where id = new.company_id for update;
  select f.max_properties into v_max from public.rg_plan_for(new.company_id) f;
  if v_max is null then return new; end if;
  select count(*) into v_active from public.properties
   where company_id = new.company_id and archived_at is null and id is distinct from new.id;
  if v_active >= v_max then
    raise exception 'Your Free plan covers up to % active properties. Archive one you no longer manage, or upgrade to Pro.', v_max
      using errcode = 'P0001', hint = 'plan_limit';
  end if;
  return new;
end;
$$;
revoke all on function public.rg_properties_plan_limit() from public, anon, authenticated;

create trigger trg_properties_plan_limit
  before insert or update of archived_at, company_id on public.properties
  for each row execute function public.rg_properties_plan_limit();
