-- rg_36: public copies of the property photos a landlord picks for a listing.
--
-- Property photos (rg_33) are private. A listing is public, so on publish-listing.html the landlord ticks which
-- property photos to show; the page copies each one to this PUBLIC bucket and adds its public URL to
-- properties.listing_photos (the same list pasted links go into). After a successful save the page removes copies
-- that are no longer on the listing, so a photo taken off the listing doesn't stay public.
--
--   bucket listing-photos (public read by URL), path <company_id>/<property_id>/<property_photo_id>.jpg
--   signed-in users with access to the company may list, upload, overwrite and remove files in its folder.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('listing-photos', 'listing-photos', true, 10485760, array['image/jpeg', 'image/png', 'image/webp']);

create policy rg_listing_photos_select on storage.objects for select to authenticated
  using (bucket_id = 'listing-photos' and public.rg_company_access(public.rg_try_uuid((storage.foldername(name))[1])));
create policy rg_listing_photos_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'listing-photos' and public.rg_company_access(public.rg_try_uuid((storage.foldername(name))[1])));
create policy rg_listing_photos_update on storage.objects for update to authenticated
  using (bucket_id = 'listing-photos' and public.rg_company_access(public.rg_try_uuid((storage.foldername(name))[1])))
  with check (bucket_id = 'listing-photos' and public.rg_company_access(public.rg_try_uuid((storage.foldername(name))[1])));
create policy rg_listing_photos_delete on storage.objects for delete to authenticated
  using (bucket_id = 'listing-photos' and public.rg_company_access(public.rg_try_uuid((storage.foldername(name))[1])));
