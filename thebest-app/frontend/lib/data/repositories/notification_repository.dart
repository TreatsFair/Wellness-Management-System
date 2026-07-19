import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/outlets/outlet_context.dart';
import 'repository_utils.dart';

/// A row from the `notifications` table (created by database triggers), or a
/// locally synthesized "starting soon" entry (type [startingSoonType]) that is
/// never persisted.
class AppNotification {
  const AppNotification({
    required this.id,
    required this.type,
    required this.title,
    required this.body,
    required this.createdAt,
    this.appointmentId = '',
    this.appointmentGroupId = '',
    this.transactionId = '',
    this.bookingHoldId = '',
    this.readAt,
  });

  factory AppNotification.fromRow(Map<String, dynamic> row) {
    return AppNotification(
      id: asString(row['id']),
      type: asString(row['type']),
      title: asString(row['title']),
      body: asString(row['body']),
      appointmentId: asString(row['appointment_id'] ?? row['appointmentId']),
      appointmentGroupId: asString(
        row['appointment_group_id'] ?? row['appointmentGroupId'],
      ),
      transactionId: asString(row['transaction_id'] ?? row['transactionId']),
      bookingHoldId: asString(
        row['booking_hold_id'] ?? row['bookingHoldId'],
      ),
      createdAt:
          asDateTime(row['created_at'] ?? row['createdAt'])?.toLocal() ??
          DateTime.now(),
      readAt: asDateTime(row['read_at'] ?? row['readAt'])?.toLocal(),
    );
  }

  static const startingSoonType = 'appointment_starting_soon';

  final String id;
  final String type;
  final String title;
  final String body;
  final String appointmentId;
  final String appointmentGroupId;
  final String transactionId;
  final String bookingHoldId;
  final DateTime createdAt;
  final DateTime? readAt;

  bool get isUnread => readAt == null && type != startingSoonType;
  bool get linksToTransaction => transactionId.isNotEmpty;
  bool get linksToAppointment =>
      appointmentId.isNotEmpty || appointmentGroupId.isNotEmpty;
  bool get hasOpenableTarget => linksToTransaction || linksToAppointment;
}

class NotificationRepository {
  SupabaseClient get _client => Supabase.instance.client;
  String get _outletId => OutletContext.activeOutletId.value;

  /// Newest-first page of the feed. Callers pass a growing [limit] for
  /// "load more" (offset paging breaks when new rows arrive at the top).
  Future<List<AppNotification>> getNotifications({int limit = 30}) async {
    final rows = await _client
        .from('notifications')
        .select()
        .eq('outlet_id', _outletId)
        .order('created_at', ascending: false)
        .limit(limit);
    return (rows as List)
        .whereType<Map>()
        .map((row) => AppNotification.fromRow(Map<String, dynamic>.from(row)))
        .toList();
  }

  Future<int> unreadCount() async {
    final rows = await _client
        .from('notifications')
        .select('id')
        .eq('outlet_id', _outletId)
        .isFilter('read_at', null)
        .limit(100);
    return (rows as List).length;
  }

  Future<void> markAllRead() async {
    await _client
        .from('notifications')
        .update({'read_at': DateTime.now().toUtc().toIso8601String()})
        .eq('outlet_id', _outletId)
        .isFilter('read_at', null);
  }

  Future<void> markRead(String id) async {
    if (id.isEmpty) return;
    await _client
        .from('notifications')
        .update({'read_at': DateTime.now().toUtc().toIso8601String()})
        .eq('id', id)
        .isFilter('read_at', null);
  }

  /// Realtime inserts for the active outlet. Returns the channel so the
  /// caller can pass it to [unsubscribe] on dispose or outlet switch.
  RealtimeChannel subscribeToInserts(
    void Function(AppNotification notification) onInsert,
  ) {
    final outletId = _outletId;
    return _client
        .channel('notifications-feed-$outletId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'notifications',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'outlet_id',
            value: outletId,
          ),
          callback: (payload) {
            final record = payload.newRecord;
            if (record.isEmpty) return;
            onInsert(AppNotification.fromRow(record));
          },
        )
        .subscribe();
  }

  Future<void> unsubscribe(RealtimeChannel channel) {
    return _client.removeChannel(channel);
  }
}
