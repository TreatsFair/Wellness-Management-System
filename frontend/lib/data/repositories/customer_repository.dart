import '../services/supabase_table_service.dart';
import 'appointment_repository.dart';
import 'repository_utils.dart';

class CustomerRepository {
  CustomerRepository({SupabaseTableService? table})
    : _table = table ?? SupabaseTableService('customers'),
      _appointments = AppointmentRepository();

  final SupabaseTableService _table;
  final AppointmentRepository _appointments;

  Future<List<Map<String, dynamic>>> getCustomers() {
    return _table.list(orderBy: 'name');
  }

  Future<List<Map<String, dynamic>>> listCustomers() => getCustomers();

  Future<List<Map<String, dynamic>>> searchCustomers(String query) async {
    final normalized = query.trim().toLowerCase();
    final rows = await getCustomers();
    if (normalized.isEmpty) return rows;
    return rows.where((row) {
      return asString(row['name']).toLowerCase().contains(normalized) ||
          asString(row['phone']).toLowerCase().contains(normalized);
    }).toList();
  }

  Future<Map<String, dynamic>?> getCustomer(String id) => _table.getById(id);

  Future<Map<String, dynamic>> addCustomer(Map<String, dynamic> values) {
    return _table.create(values);
  }

  Future<Map<String, dynamic>> createCustomer(Map<String, dynamic> values) {
    return addCustomer(values);
  }

  Future<Map<String, dynamic>> updateCustomer(
    String id,
    Map<String, dynamic> values,
  ) {
    return _table.update(id, values);
  }

  Future<void> deleteCustomer(String id) => _table.delete(id);

  Future<Map<String, dynamic>> getCustomerAppointmentStats(String id) async {
    final appointments = await _appointments.getAppointmentsByCustomer(id);
    double totalSales = 0;
    String lastVisit = '-';

    appointments.sort(
      (a, b) => asString(b['date']).compareTo(asString(a['date'])),
    );

    for (final appointment in appointments) {
      totalSales += asDouble(appointment['totalPrice']);
    }
    if (appointments.isNotEmpty) {
      lastVisit = asString(appointments.first['date'], '-');
    }

    return {
      'appointmentCount': appointments.length,
      'totalSales': totalSales,
      'lastVisit': lastVisit,
    };
  }
}
