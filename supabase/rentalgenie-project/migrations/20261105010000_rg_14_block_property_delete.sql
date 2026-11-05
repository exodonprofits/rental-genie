-- rg_14: properties can't be hard-deleted through the API; they're archived (archive_property)
-- instead, like expenses (expenses_no_hard_delete).
--
-- The old properties_no_delete was a PERMISSIVE "using (false)", which blocks nothing: permissive
-- policies are OR'd, so the owner/company-member policy still allowed DELETE. rg_13 dropped it. A
-- RESTRICTIVE policy is AND'd with the permissive ones, so this one denies every DELETE for signed-in
-- users. No page, Edge Function or database function deletes properties; the service role (n8n,
-- Edge Functions) bypasses RLS and is unaffected.

create policy properties_no_hard_delete on public.properties
  as restrictive
  for delete to authenticated
  using (false);
