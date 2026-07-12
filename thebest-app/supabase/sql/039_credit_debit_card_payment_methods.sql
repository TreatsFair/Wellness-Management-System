-- Split the single "card" payment method into Credit Card and Debit Card.
-- RENAME VALUE is non-destructive: every existing transactions.payment_method
-- = 'card' row becomes 'credit_card' automatically, no data rewrite needed.

alter type public.payment_method rename value 'card' to 'credit_card';
alter type public.payment_method add value 'debit_card';
