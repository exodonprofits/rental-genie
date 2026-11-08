-- rg_20: allow the landlord alert kinds in the notification log (rg_17 allowed maintenance_ack only).
-- Kept apart from rg_21 because replacing a check constraint needs a confirmation in the Supabase tools.

alter table public.notifications drop constraint notifications_kind_check;
alter table public.notifications add constraint notifications_kind_check
  check (kind in ('maintenance_ack', 'landlord_repair', 'landlord_message'));
