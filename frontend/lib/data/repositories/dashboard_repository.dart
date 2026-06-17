import '../services/supabase_table_service.dart';
import 'appointment_repository.dart';
import 'repository_utils.dart';

class DashboardRepository {
  DashboardRepository({
    SupabaseTableService? appointments,
    SupabaseTableService? customers,
    SupabaseTableService? therapists,
    SupabaseTableService? transactions,
  }) : _appointments = appointments ?? SupabaseTableService('appointments'),
       _customers = customers ?? SupabaseTableService('customers'),
       _therapists = therapists ?? SupabaseTableService('therapists'),
       _transactions = transactions ?? SupabaseTableService('transactions');

  final SupabaseTableService _appointments;
  final SupabaseTableService _customers;
  final SupabaseTableService _therapists;
  final SupabaseTableService _transactions;

  Future<List<Map<String, dynamic>>> appointmentsForDate(String date) {
    return _appointments.findBy(
      'appointment_date',
      date,
      orderBy: 'start_time',
    );
  }

  Future<List<Map<String, dynamic>>> appointmentsForDateRange(
    String startDate,
    String endDate,
  ) {
    return _appointments.findBetween(
      'appointment_date',
      startDate,
      endDate,
      orderBy: 'appointment_date',
    );
  }

  Future<List<Map<String, dynamic>>> listCustomers() {
    return _customers.list(orderBy: 'name');
  }

  Future<List<Map<String, dynamic>>> listTherapists() {
    return _therapists.list(orderBy: 'name');
  }

  Future<List<Map<String, dynamic>>> recentTransactions({int limit = 8}) {
    return _transactions.list(
      orderBy: 'created_at',
      ascending: false,
      limit: limit,
    );
  }

  Future<List<Map<String, dynamic>>> transactionsForDate(DateTime date) async {
    final key = dateKey(date);
    final rows = await _transactions.list(
      orderBy: 'created_at',
      ascending: false,
    );
    return rows.where((row) {
      final createdAt = asDateTime(row['createdAt']);
      return createdAt != null && dateKey(createdAt) == key;
    }).toList();
  }

  Future<List<Map<String, dynamic>>> transactionsForDateRange(
    DateTime start,
    DateTime end,
  ) async {
    final startKey = dateKey(start);
    final endKey = dateKey(end);
    final rows = await _transactions.list(
      orderBy: 'created_at',
      ascending: false,
    );
    return rows.where((row) {
      final createdAt = asDateTime(row['createdAt']);
      if (createdAt == null) return false;
      final key = dateKey(createdAt);
      return key.compareTo(startKey) >= 0 && key.compareTo(endKey) < 0;
    }).toList();
  }

  Future<Map<String, Map<String, dynamic>>> loadByIds(
    String table,
    Iterable<String> ids,
  ) async {
    final rows = await SupabaseTableService(table).getManyByIds(ids);
    return {for (final row in rows) asString(row['id']): row};
  }

  Future<int> getTodayBookingCount() async {
    final rows = await appointmentsForDate(dateKey(DateTime.now()));
    return rows.where((row) {
      final status = asString(row['status']).toLowerCase();
      final type = asString(row['type']).toLowerCase();
      if (type == 'walkin' || type == 'walk-in' || type == 'walk_in') {
        return false;
      }
      return status != 'cancelled' && status != 'canceled';
    }).length;
  }

  Future<double> getTodayRevenue() async {
    final rows = await transactionsForDate(DateTime.now());
    return rows.fold<double>(0, (total, row) {
      final status = asString(row['paymentStatus']).toLowerCase();
      if (status.isNotEmpty && status != 'paid') return total;
      return total + asDouble(row['totalAmount']);
    });
  }

  Future<int> getPendingAppointmentCount() async {
    final rows = await appointmentsForDate(dateKey(DateTime.now()));
    return rows
        .where((row) => asString(row['status']).toLowerCase() == 'pending')
        .length;
  }

  Future<List<Map<String, dynamic>>> getTherapistStatus() async {
    final today = dateKey(DateTime.now());
    final therapists = await listTherapists();
    final appointmentRepository = AppointmentRepository();
    final statuses = <Map<String, dynamic>>[];
    for (final therapist in therapists) {
      final rows = await appointmentRepository
          .getActiveAppointmentsForTherapist(asString(therapist['id']), today);
      statuses.add({...therapist, 'activeAppointments': rows});
    }
    return statuses;
  }

  Future<Map<String, dynamic>> getDashboardSummary() async {
    final today = DateTime.now();
    return {
      'todayBookingCount': await getTodayBookingCount(),
      'todayRevenue': await getTodayRevenue(),
      'pendingAppointmentCount': await getPendingAppointmentCount(),
      'todayTransactions': await transactionsForDate(today),
      'therapistStatus': await getTherapistStatus(),
    };
  }
}
