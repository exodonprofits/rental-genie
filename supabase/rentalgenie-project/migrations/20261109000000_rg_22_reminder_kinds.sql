-- rg_22: allow the scheduled reminder kinds in the notification log (and the monthly summary, so the
-- next one doesn't need this again). Kept apart from rg_23: replacing a check constraint needs a
-- confirmation in the Supabase tools.

alter table public.notifications drop constraint notifications_kind_check;
alter table public.notifications add constraint notifications_kind_check
  check (kind in ('maintenance_ack', 'landlord_repair', 'landlord_message',
                  'rent_due', 'rent_overdue', 'lease_expiry', 'monthly_summary'));
