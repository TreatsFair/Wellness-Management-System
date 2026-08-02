alter table public.audit_log
drop constraint if exists audit_log_action_check;

alter table public.audit_log
add constraint audit_log_action_check
check (action in ('INSERT', 'UPDATE', 'DELETE', 'SECURE_CHECKOUT'));
