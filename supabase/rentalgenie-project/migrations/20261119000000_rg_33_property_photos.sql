-- rg_33: property photos (private). Uploaded on Edit Property (add-property.html?edit=1); the cover shows on the
-- Properties cards (property-management.html). Only people with access to the company see them: the bucket is
-- private and pages open photos through signed links.
--
--   storage   bucket property-photos, path <company_id>/<property_id>/<file>; images up to 10 MB (pages resize first)
--   table     property_photos, one row per photo; archived, never deleted. The cover is the first photo by
--             (sort_order, created_at): "make cover" sets sort_order below the others, one update, no flag to keep
--             unique. company_id is always the property's (guard trigger), so access follows the property.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('property-photos', 'property-photos', false, 10485760,
        array['image/jpeg', 'image/png', 'image/webp', 'image/heic', 'image/heif']);

create table public.property_photos (
  id           uuid primary key default gen_random_uuid(),
  company_id   uuid not null references public.companies(id),
  property_id  uuid not null references public.properties(id),
  storage_path text not null unique,
  caption      text check (caption is null or char_length(caption) <= 200),
  sort_order   int  not null default 0,
  created_by   uuid default auth.uid(),
  created_at   timestamptz not null default now(),
  archived_at  timestamptz,
  archived_by  uuid
);
create index property_photos_property_idx on public.property_photos (property_id, sort_order, created_at) where archived_at is null;
create index property_photos_company_idx  on public.property_photos (company_id) where archived_at is null;

-- company_id from the property; the file must sit in that company's and property's folder; property and file are
-- fixed once saved; at most 40 active photos per property.
create or replace function public.rg_property_photos_guard()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_company uuid; v_count int;
begin
  if tg_op = 'UPDATE' then
    if new.property_id is distinct from old.property_id or new.storage_path is distinct from old.storage_path
       or new.company_id is distinct from old.company_id or new.created_by is distinct from old.created_by
       or new.created_at is distinct from old.created_at then
      raise exception 'A photo can''t be moved to another property or file.' using errcode = '22023';
    end if;
    if new.archived_at is null and old.archived_at is not null then
      raise exception 'Removed photos can''t be restored. Upload the photo again.' using errcode = '22023';
    end if;
    if new.archived_at is not null and old.archived_at is null then new.archived_by := auth.uid(); end if;
    return new;
  end if;
  select company_id into v_company from public.properties where id = new.property_id;
  if v_company is null then raise exception 'Property not found.' using errcode = '22023'; end if;
  new.company_id := v_company;
  new.created_by := auth.uid();
  new.created_at := now();
  new.archived_at := null; new.archived_by := null;
  if new.storage_path not like v_company::text || '/' || new.property_id::text || '/%' then
    raise exception 'Photo file is in the wrong folder.' using errcode = '22023';
  end if;
  select count(*) into v_count from public.property_photos where property_id = new.property_id and archived_at is null;
  if v_count >= 40 then
    raise exception 'A property can have up to 40 photos. Remove one first.' using errcode = '22023';
  end if;
  return new;
end;
$$;
revoke all on function public.rg_property_photos_guard() from public, anon, authenticated;
create trigger trg_property_photos_guard before insert or update on public.property_photos
  for each row execute function public.rg_property_photos_guard();

alter table public.property_photos enable row level security;
revoke all on public.property_photos from anon;
revoke delete, truncate on public.property_photos from authenticated;
create policy property_photos_select on public.property_photos for select to authenticated
  using (public.rg_company_access(company_id));
create policy property_photos_insert on public.property_photos for insert to authenticated
  with check (public.rg_company_access(company_id));
create policy property_photos_update on public.property_photos for update to authenticated
  using (public.rg_company_access(company_id)) with check (public.rg_company_access(company_id));

-- Files: read and upload within a company you can access. No update or delete: removing a photo archives its row.
create policy rg_property_photos_select on storage.objects for select to authenticated
  using (bucket_id = 'property-photos' and public.rg_company_access(public.rg_try_uuid((storage.foldername(name))[1])));
create policy rg_property_photos_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'property-photos' and public.rg_company_access(public.rg_try_uuid((storage.foldername(name))[1])));
