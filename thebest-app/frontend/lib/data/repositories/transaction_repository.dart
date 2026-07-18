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

  Future<List<Map<String, dynamic>>> getTransactionsByCustomer(
    String customerId,
  ) {
    return _table.findBy(
      'customer_id',
      customerId,
      orderBy: 'created_at',
      ascending: false,
    );
  }

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

  Future<Map<String, dynamic>?> getTransactionByReceiptNumber(
    String receiptNumber,
  ) async {
    final rows = await _table.findBy(
      'receipt_number',
      receiptNumber,
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<List<Map<String, dynamic>>> getLinkedAppointmentTransactions({
    String appointmentId = '',
    String appointmentGroupId = '',
  }) {
    if (appointmentGroupId.trim().isNotEmpty) {
      return _table.findBy(
        'appointment_group_id',
        appointmentGroupId,
        orderBy: 'created_at',
      );
    }
    if (appointmentId.trim().isNotEmpty) {
      return _table.findBy(
        'appointment_id',
        appointmentId,
        orderBy: 'created_at',
      );
    }
    return Future.value(const <Map<String, dynamic>>[]);
  }

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
