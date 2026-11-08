-- rg_18: run the notification retry sweep (rg_17) every 5 minutes with pg_cron.
-- Kept apart from rg_17 so a problem enabling the extension can't roll back the notification log.
-- The sweep is a single indexed query when nothing is due.

create extension if not exists pg_cron;

select cron.schedule('rg-notification-sweep', '*/5 * * * *', 'select public.rg_notification_sweep()');
