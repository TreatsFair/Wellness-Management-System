-- Keep historical Billplz records unchanged; new Fiuu receipts use their own method.
alter type public.payment_method add value if not exists 'fiuu';
