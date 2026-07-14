-- Root cause of "online bookings never show paid": record_online_booking_payment
-- (033) inserts payment_method = 'billplz', but the payment_method enum only had
-- {cash, qr_code, credit_card, debit_card}. So that INSERT raised
-- "invalid input value for enum payment_method: billplz" on EVERY Billplz
-- callback -- the callback caught it and still returned 200, so the payment was
-- silently never recorded (zero online_booking transactions / BP- receipts ever
-- existed). Reports already map payment_method 'billplz' -> the "Online" bucket.
--
-- Adding the missing value makes the callback record online payments correctly.
-- Own migration: ALTER TYPE ADD VALUE cannot be used in the same transaction it
-- is added in, and nothing here uses it.

alter type public.payment_method add value if not exists 'billplz';
