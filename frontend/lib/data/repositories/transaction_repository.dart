import '../services/supabase_table_service.dart';
import 'repository_utils.dart';

class TransactionRepository {
  TransactionRepository({SupabaseTableService? table})
    : _table = table ?? SupabaseTableService('transactions');

  final SupabaseTableService _table;

  Future<List<Map<String, dynamic>>> listTransactions() {
    return _table.list(orderBy: 'created_at', ascending: false);
  }

  Future<List<Map<String, dynamic>>> getTransactions() => listTransactions();

  Future<List<Map<String, dynamic>>> getTransactionsByDate(
    DateTime date,
  ) async {
    final target = dateKey(date);
    final rows = await listTransactions();
    return rows.where((row) {
      final createdAt = asDateTime(row['createdAt']);
      return createdAt != null && dateKey(createdAt) == target;
    }).toList();
  }

  Future<List<Map<String, dynamic>>> recentTransactions({int limit = 8}) {
    return _table.list(orderBy: 'created_at', ascending: false, limit: limit);
  }

  Future<Map<String, dynamic>?> getTransaction(String id) => _table.getById(id);

  Future<Map<String, dynamic>> createTransaction(Map<String, dynamic> values) {
    return _table.create({
      ...values,
      'createdAt': values['createdAt'] ?? DateTime.now().toIso8601String(),
    });
  }

  Future<Map<String, dynamic>> updateTransaction(
    String id,
    Map<String, dynamic> values,
  ) {
    return _table.update(id, values);
  }

  Future<void> deleteTransaction(String id) => _table.delete(id);

  Future<List<Map<String, dynamic>>> getSalesHistory(DateTime date) {
    return getTransactionsByDate(date);
  }

  Future<String> generateReceiptNumber() async {
    return 'TR${compactTimestamp(DateTime.now())}';
  }
}
