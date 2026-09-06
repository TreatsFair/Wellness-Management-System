import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:frontend/data/repositories/dashboard_repository.dart';
import 'package:frontend/data/services/supabase_table_service.dart';

class _FakeTableService extends SupabaseTableService {
  _FakeTableService(this.rows)
    : super(
        'transactions',
        client: SupabaseClient('https://example.supabase.co', 'test-key'),
      );

  final List<Map<String, dynamic>> rows;

  @override
  Future<List<Map<String, dynamic>>> list({
    String? orderBy,
    bool ascending = true,
    int? limit,
  }) async {
    return rows;
  }
}

void main() {
  test('Dashboard keeps a UTC transaction on its Malaysia-local business day', () async {
    final transaction = <String, dynamic>{
      'createdAt': '2026-09-05T18:40:46.428794Z',
    };
    final table = _FakeTableService([transaction]);
    final repository = DashboardRepository(
      appointments: table,
      customers: table,
      therapists: table,
      transactions: table,
    );

    final today = DateTime(2026, 9, 6);
    final todayRows = await repository.transactionsForDate(today);
    final todayRangeRows = await repository.transactionsForDateRange(
      today,
      today.add(const Duration(days: 1)),
    );

    expect(todayRows, hasLength(1));
    expect(todayRangeRows, hasLength(1));
  });
}
