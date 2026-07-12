import 'package:supabase_flutter/supabase_flutter.dart';

/// Renders an error as text suitable for a SnackBar, unwrapping
/// [PostgrestException] to its `message` instead of the raw
/// `PostgrestException(message: ..., code: ..., details: ..., hint: ...)`
/// toString that Postgrest/Supabase throws.
String friendlyErrorMessage(Object error) {
  if (error is PostgrestException) {
    return error.message;
  }
  return error.toString();
}
