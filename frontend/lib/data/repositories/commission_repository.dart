import 'repository_utils.dart';
import 'therapist_repository.dart';

class CommissionRepository {
  CommissionRepository({TherapistRepository? therapistRepository})
    : _therapistRepository = therapistRepository ?? TherapistRepository();

  final TherapistRepository _therapistRepository;

  Future<Map<String, dynamic>?> getAvailableCounterStaff() {
    return _therapistRepository.getAvailableCounterStaff();
  }

  static double commissionForServices(
    Iterable<Map<String, dynamic>> services, {
    required Map<String, dynamic>? staff,
    required String role,
  }) {
    return services.fold<double>(
      0,
      (total, service) =>
          total + commissionForService(service, staff: staff, role: role),
    );
  }

  static double commissionForService(
    Map<String, dynamic> service, {
    required Map<String, dynamic>? staff,
    required String role,
  }) {
    final serviceId = asString(service['id'], asString(service['serviceId']));
    final overrides = _commissionMap(staff?['serviceCommissions']);
    if (serviceId.isNotEmpty && overrides.containsKey(serviceId)) {
      return overrides[serviceId]!;
    }

    return _normalizeRole(role) == 'Counter'
        ? asDouble(service['counterCommission'])
        : asDouble(service['therapistCommission']);
  }
}

Map<String, double> _commissionMap(Object? value) {
  if (value is! Map) return {};
  final result = <String, double>{};
  value.forEach((key, item) {
    result[key.toString()] = asDouble(item);
  });
  return result;
}

String _normalizeRole(String value) {
  final normalized = value.trim().toLowerCase();
  if (normalized.contains('counter') || normalized.contains('cashier')) {
    return 'Counter';
  }
  return 'Therapist';
}
