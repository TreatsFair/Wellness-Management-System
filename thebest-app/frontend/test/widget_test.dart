import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/core/supabase/supabase_config.dart';
import 'package:frontend/data/repositories/profile_repository.dart';

void main() {
  test('Supabase config is available', () {
    expect(Uri.parse(SupabaseConfig.url).host, isNotEmpty);
    expect(SupabaseConfig.publishableKey, startsWith('sb_publishable_'));
  });

  test('profile role values are normalized', () {
    final profile = UserProfile.fromMap({
      'id': 'user-id',
      'name': 'Admin User',
      'email': 'admin@example.com',
      'role': ' Admin ',
    });

    expect(profile.role, 'admin');
    expect(profile.isAdmin, isTrue);
    expect(profile.isStaff, isFalse);
  });
}
