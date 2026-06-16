import 'package:supabase_flutter/supabase_flutter.dart';

class AuthRepositoryException implements Exception {
  const AuthRepositoryException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() => message;
}

class AuthRepository {
  AuthRepository({SupabaseClient? client})
    : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  User? get currentUser => _client.auth.currentUser;

  Session? get currentSession => _client.auth.currentSession;

  Stream<AuthState> get authStateChanges => _client.auth.onAuthStateChange;

  Stream<Session?> get sessionChanges =>
      authStateChanges.map((state) => state.session);

  Future<AuthResponse> signIn(String email, String password) async {
    try {
      return await _client.auth.signInWithPassword(
        email: email.trim(),
        password: password,
      );
    } on AuthException catch (error) {
      throw AuthRepositoryException(_authMessage(error), error);
    }
  }

  Future<void> signOut() async {
    try {
      await _client.auth.signOut();
    } on AuthException catch (error) {
      throw AuthRepositoryException(_authMessage(error), error);
    }
  }

  Future<void> resetPassword(String email) async {
    try {
      await _client.auth.resetPasswordForEmail(email.trim());
    } on AuthException catch (error) {
      throw AuthRepositoryException(_authMessage(error), error);
    }
  }

  String _authMessage(AuthException error) {
    final message = error.message.toLowerCase();
    if (message.contains('invalid login credentials')) {
      return 'Invalid email or password';
    }
    if (message.contains('email not confirmed')) {
      return 'Email is not confirmed';
    }
    if (message.contains('user not found')) {
      return 'No account found for this email';
    }
    if (message.contains('rate limit') || message.contains('too many')) {
      return 'Too many attempts. Try again later';
    }
    return error.message.isEmpty ? 'Authentication failed' : error.message;
  }
}
