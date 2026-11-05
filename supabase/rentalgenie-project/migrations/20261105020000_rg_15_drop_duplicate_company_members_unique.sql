-- rg_15: drop company_members_company_user_unique, an exact duplicate of company_members_pkey
-- (both are UNIQUE btree on (company_id, user_id); advisor duplicate_index). The primary key keeps
-- enforcing one membership per user per company, and ON CONFLICT (company_id, user_id) still
-- resolves to it. Nothing references the constraint by name and no foreign key points at
-- company_members.

alter table public.company_members drop constraint company_members_company_user_unique;
