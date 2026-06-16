import 'package:supabase_flutter/supabase_flutter.dart';

class UserProfile {
  const UserProfile({
    required this.id,
    required this.name,
    required this.email,
    required this.role,
    this.createdAt,
  });

  final String id;
  final String name;
  final String email;
  final String role;
  final DateTime? createdAt;

  bool get isAdmin => role == 'admin';

  bool get isStaff => role == 'staff';

  factory UserProfile.fromMap(Map<String, dynamic> data) {
    final createdAtValue = data['created_at'];
    return UserProfile(
      id: (data['id'] ?? '').toString(),
      name: (data['name'] ?? '').toString(),
      email: (data['email'] ?? '').toString(),
      role: (data['role'] ?? 'staff').toString().toLowerCase().trim(),
      createdAt: createdAtValue is DateTime
          ? createdAtValue
          : DateTime.tryParse((createdAtValue ?? '').toString()),
    );
  }
}

class ProfileRepository {
  ProfileRepository({SupabaseClient? client})
    : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  Future<UserProfile?> getCurrentProfile() async {
    final user = _client.auth.currentUser;
    if (user == null) return null;

    final data = await _client
        .from('profiles')
        .select('id, name, email, role, created_at')
        .eq('id', user.id)
        .maybeSingle();

    if (data == null) return null;
    return UserProfile.fromMap(data);
  }

  Future<String?> getCurrentRole() async {
    final profile = await getCurrentProfile();
    return profile?.role;
  }

  Future<bool> isAdmin() async {
    final role = await getCurrentRole();
    return role == 'admin';
  }

  Future<bool> isStaff() async {
    final role = await getCurrentRole();
    return role == 'staff';
  }
}
