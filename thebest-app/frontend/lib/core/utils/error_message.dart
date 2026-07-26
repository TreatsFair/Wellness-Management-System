import 'package:supabase_flutter/supabase_flutter.dart';

class AppointmentOperationException implements Exception {
  const AppointmentOperationException({
    required this.code,
    required this.message,
  });

  final String code;
  final String message;

  @override
  String toString() => message;
}

/// Renders an error as text suitable for a SnackBar, unwrapping
/// [PostgrestException] to its `message` instead of the raw
/// `PostgrestException(message: ..., code: ..., details: ..., hint: ...)`
/// toString that Postgrest/Supabase throws.
String friendlyErrorMessage(Object error) {
  if (error is AppointmentOperationException) {
    return switch (error.code.toUpperCase()) {
      'THERAPIST_BUSY' =>
        'That therapist is busy during this service window. Choose another therapist.',
      'THERAPIST_UNAVAILABLE' =>
        'That therapist is not available for assignment.',
      'OUTSIDE_WORKING_HOURS' =>
        'That therapist is outside their working hours.',
      'INVALID_THERAPIST' => 'That therapist is no longer available.',
      _ => error.message,
    };
  }
  if (error is PostgrestException) {
    return error.message;
  }
  return error.toString();
}

/// Replaces legacy CSP fallback text that incorrectly describes every staff
/// availability failure as a booking conflict. When no concrete busy-until
/// time is returned, the failure may instead be caused by working hours or
/// leave.
String friendlyBookingErrorMessage(
  String? errorMessage, {
  String fallback = 'Unable to complete this booking',
}) {
  final message = errorMessage?.trim();
  if (message == null || message.isEmpty) return fallback;

  if (message.toLowerCase() == 'staff is booked until later.') {
    return 'Staff is unavailable for this time. Check the outlet hours and staff schedule.';
  }

  return message;
}
