# Treats Wellness Management System

A wellness centre management system developed for Capstone Project 2.

The system helps staff and administrators manage:

- appointments and walk-ins
- customers, therapists and rooms
- therapist queue rotation and availability
- services, prices and commissions
- payments, receipts and transaction records
- online bookings and Billplz payments
- staff schedules and operational reports

## System Components

- Flutter staff and admin application
- Supabase PostgreSQL database
- Supabase Edge Functions
- Public booking website
- Billplz payment integration

## Technologies Used

- Flutter and Dart
- Supabase Auth and PostgreSQL
- TypeScript and Deno
- HTML, CSS and JavaScript
- Billplz
- Git and GitHub

## Project Structure

```text
thebest-app/frontend              Flutter application
thebest-app/supabase              Database migrations and Edge Functions
thebest-website                   Public website and booking pages
ops                               Maintenance scripts
```

## Running the Flutter Application on Chrome

### Staging

```bash
cd thebest-app/frontend
flutter run -d chrome -t lib/main_staging.dart
```

### Production

```bash
cd thebest-app/frontend
flutter run -d chrome -t lib/main_production.dart
```

## Website

https://thebestwellness.my

## Notes

- Staging and Production use separate Supabase projects.
- Billplz Sandbox is used for Staging.
- Billplz Live is used for Production.

