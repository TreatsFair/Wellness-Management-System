import '../services/supabase_table_service.dart';
import '../../core/outlets/outlet_context.dart';
import 'repository_utils.dart';

/// Per-day opening hours for the active outlet.
///
/// Saving a day propagates to every therapist who has not overridden that day
/// on their profile (`therapist_working_hours.is_custom`) — the propagation
/// itself lives in Postgres, see `088_per_day_business_hours.sql`.
class BusinessHoursRepository {
  BusinessHoursRepository({SupabaseTableService? table})
    : _table = table ?? SupabaseTableService('business_hours');

  final SupabaseTableService _table;

  Future<List<BusinessDayHours>> listWeek() async {
    final rows = await _table.list(orderBy: 'day_of_week');
    final byDay = <int, BusinessDayHours>{
      for (final row in rows.map(BusinessDayHours.fromMap)) row.dayOfWeek: row,
    };
    return List.generate(
      7,
      (day) => byDay[day] ?? BusinessDayHours.fallback(day),
    );
  }

  Future<void> saveDay(BusinessDayHours day) async {
    await saveWeek([day]);
  }

  Future<void> saveWeek(List<BusinessDayHours> days) async {
    if (days.isEmpty) return;

    // A single PostgREST upsert is atomic. This matters for "Apply to all": a
    // network failure must not leave only part of the week changed.
    await _table.client.from('business_hours').upsert([
      for (final day in days)
        {
          'outlet_id': OutletContext.activeOutletId.value,
          'day_of_week': day.dayOfWeek,
          'open_time': day.openStorage,
          'close_time': day.closeStorage,
          'is_closed': day.isClosed,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
    ], onConflict: 'outlet_id,day_of_week');
  }
}

class BusinessDayHours {
  const BusinessDayHours({
    required this.id,
    required this.dayOfWeek,
    required this.openTime,
    required this.closeTime,
    required this.isClosed,
  });

  /// Empty when the row does not exist in the database yet.
  final String id;

  /// Postgres convention: 0 = Sunday, 1 = Monday … 6 = Saturday.
  final int dayOfWeek;

  /// `HH:mm`.
  final String openTime;
  final String closeTime;
  final bool isClosed;

  factory BusinessDayHours.fallback(int dayOfWeek) => BusinessDayHours(
    id: '',
    dayOfWeek: dayOfWeek,
    openTime: '09:00',
    closeTime: '21:00',
    isClosed: false,
  );

  factory BusinessDayHours.fromMap(Map<String, dynamic> row) {
    final fallback = BusinessDayHours.fallback(
      asInt(row['dayOfWeek'] ?? row['day_of_week'], 0),
    );
    return BusinessDayHours(
      id: asString(row['id']),
      dayOfWeek: fallback.dayOfWeek,
      openTime: _shortTime(row['openTime'] ?? row['open_time'], '09:00'),
      closeTime: _shortTime(row['closeTime'] ?? row['close_time'], '21:00'),
      isClosed: asBool(row['isClosed'] ?? row['is_closed'], false),
    );
  }

  BusinessDayHours copyWith({
    String? openTime,
    String? closeTime,
    bool? isClosed,
  }) => BusinessDayHours(
    id: id,
    dayOfWeek: dayOfWeek,
    openTime: openTime ?? this.openTime,
    closeTime: closeTime ?? this.closeTime,
    isClosed: isClosed ?? this.isClosed,
  );

  String get openStorage => '$openTime:00';
  String get closeStorage => '$closeTime:00';

  /// True when the day runs past midnight, e.g. 21:00 – 02:00.
  bool get isOvernight => closeTime.compareTo(openTime) <= 0;

  bool sameHoursAs(BusinessDayHours other) =>
      openTime == other.openTime &&
      closeTime == other.closeTime &&
      isClosed == other.isClosed;
}

String _shortTime(Object? value, String fallback) {
  final text = asString(value, fallback);
  return text.length >= 5 ? text.substring(0, 5) : fallback;
}
