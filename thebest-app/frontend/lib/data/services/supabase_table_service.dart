import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/outlets/outlet_context.dart';

const Map<String, String> _snakeToCamelAliases = {
  'appointment_id': 'appointmentId',
  'appointment_date': 'date',
  'appointment_group_id': 'appointmentGroupId',
  'assignment_source': 'assignmentSource',
  'therapist_assignment_state': 'therapistAssignmentState',
  'room_assignment_state': 'roomAssignmentState',
  'therapist_auto_assigned_at': 'therapistAutoAssignedAt',
  'resources_confirmed_at': 'resourcesConfirmedAt',
  'resources_confirmed_by': 'resourcesConfirmedBy',
  'assignment_last_attempted_at': 'assignmentLastAttemptedAt',
  'assignment_error_code': 'assignmentErrorCode',
  'assignment_error_message': 'assignmentErrorMessage',
  'availability_status': 'availabilityStatus',
  'business_name': 'businessName',
  'busy_until': 'busyUntil',
  'close_time': 'closeTime',
  'auto_extend_late_arrivals': 'autoExtendLateArrivals',
  'created_at': 'createdAt',
  'created_by': 'createdBy',
  'cashier_id': 'cashierId',
  'cashier_name': 'cashierName',
  'counter_id': 'counterId',
  'customer_id': 'customerId',
  'customer_name': 'customerName',
  'customer_phone': 'customerPhone',
  'guest_name': 'guestName',
  'guest_phone': 'guestPhone',
  'counter_commission': 'counterCommission',
  'counter_commission_amount': 'counterCommissionAmount',
  'counter_staff_id': 'counterStaffId',
  'counter_staff_name': 'counterStaffName',
  'date_of_birth': 'dateOfBirth',
  'employment_type': 'employmentType',
  'end_time': 'endTime',
  'image_url': 'imageUrl',
  'is_active': 'isActive',
  'online_booking_enabled': 'onlineBookingEnabled',
  'late_grace_minutes': 'lateGraceMinutes',
  'public_open_time': 'publicOpenTime',
  'public_close_time': 'publicCloseTime',
  'slot_interval_minutes': 'slotIntervalMinutes',
  'minimum_advance_minutes': 'minimumAdvanceMinutes',
  'maximum_booking_days': 'maximumBookingDays',
  'same_day_booking_allowed': 'sameDayBookingAllowed',
  'customer_therapist_selection_allowed': 'customerTherapistSelectionAllowed',
  'public_therapist_names_allowed': 'publicTherapistNamesAllowed',
  'publicly_visible': 'publiclyVisible',
  'online_bookable': 'onlineBookable',
  'public_name': 'publicName',
  'short_description': 'shortDescription',
  'public_image_url': 'publicImageUrl',
  'display_price': 'displayPrice',
  'show_price': 'showPrice',
  'display_order': 'displayOrder',
  'buffer_before_minutes': 'bufferBeforeMinutes',
  'buffer_after_minutes': 'bufferAfterMinutes',
  'booked_date': 'bookedDate',
  'booked_start_time': 'bookedStartTime',
  'booked_end_time': 'bookedEndTime',
  'booked_start_at': 'bookedStartAt',
  'booked_end_at': 'bookedEndAt',
  'actual_started_at': 'actualStartedAt',
  'actual_completed_at': 'actualCompletedAt',
  // Migration 122k: check-in is tracked separately from service start. An
  // appointment can be checked in (status still `confirmed`) well before
  // `actualStartedAt` is set.
  'checked_in_at': 'checkedInAt',
  'checked_in_by': 'checkedInBy',
  'maximum_concurrent_bookings': 'maximumConcurrentBookings',
  'use_custom_hours': 'useCustomHours',
  'online_booking_service_id': 'onlineBookingServiceId',
  'day_of_week': 'dayOfWeek',
  'closure_date': 'closureDate',
  'is_full_day': 'isFullDay',
  'internal_reason': 'internalReason',
  'is_custom': 'isCustom',
  'is_closed': 'isClosed',
  'starts_at': 'startsAt',
  'ends_at': 'endsAt',
  'item_count': 'itemCount',
  'join_date': 'joinDate',
  'logo_url': 'logoUrl',
  'open_time': 'openTime',
  'outlet_id': 'outletId',
  'paid_at': 'paidAt',
  'payment_method': 'paymentMethod',
  'payment_status': 'paymentStatus',
  'no_show_threshold_minutes': 'noShowThresholdMinutes',
  'photo_url': 'photoUrl',
  'profile_image_url': 'profileImageUrl',
  'receipt_number': 'receiptNumber',
  'requested_therapist_id': 'requestedTherapistId',
  'requested_gender': 'requestedGender',
  'room_id': 'roomId',
  'room_name': 'roomName',
  'room_unit_id': 'roomUnitId',
  'room_unit_name': 'roomUnitName',
  'assigned_room_unit_id': 'assignedRoomUnitId',
  'allocation_mode': 'allocationMode',
  'unit_number': 'unitNumber',
  'zone_id': 'zoneId',
  'room_type': 'roomType',
  'service_description': 'serviceDescription',
  'service_id': 'serviceId',
  'service_items': 'serviceItems',
  'service_name': 'serviceName',
  'service_price': 'servicePrice',
  'service_commissions': 'serviceCommissions',
  'commission_overrides': 'commissionOverrides',
  'sst_amount': 'sstAmount',
  'sst_enabled': 'sstEnabled',
  'sst_pricing_mode': 'sstPricingMode',
  'billplz_sst_pricing_mode': 'billplzSstPricingMode',
  'counter_sst_pricing_mode': 'counterSstPricingMode',
  'appointment_addon_sst_pricing_mode': 'appointmentAddonSstPricingMode',
  'sst_rate_percent': 'sstRatePercent',
  'sst_rounding_mode': 'sstRoundingMode',
  'start_at': 'startAt',
  'start_time': 'startTime',
  'end_at': 'endAt',
  'therapist_id': 'therapistId',
  'therapist_name': 'therapistName',
  'transaction_id': 'transactionId',
  'booking_hold_id': 'bookingHoldId',
  'read_at': 'readAt',
  'total_amount': 'totalAmount',
  'total_price': 'totalPrice',
  'total_slots': 'totalSlots',
  'therapist_commission': 'therapistCommission',
  'therapist_commission_amount': 'therapistCommissionAmount',
  'updated_at': 'updatedAt',
  'updated_by': 'updatedBy',
  'delay_warning_minutes': 'delayWarningMinutes',
};

final Map<String, String> _camelToSnakeAliases = {
  for (final entry in _snakeToCamelAliases.entries) entry.value: entry.key,
  'appointmentDate': 'appointment_date',
};

class SupabaseTableService {
  SupabaseTableService(this.tableName, {SupabaseClient? client})
    : _client = client ?? Supabase.instance.client;

  final String tableName;
  final SupabaseClient _client;

  SupabaseClient get client => _client;

  bool get _isOutletScoped =>
      OutletContext.outletScopedTables.contains(tableName);
  String get _activeOutletId => OutletContext.activeOutletId.value;

  Future<List<Map<String, dynamic>>> list({
    String? orderBy,
    bool ascending = true,
    int? limit,
  }) async {
    dynamic query = _client.from(tableName).select();
    if (_isOutletScoped) query = query.eq('outlet_id', _activeOutletId);
    if (orderBy != null) {
      query = query.order(orderBy, ascending: ascending);
    }
    if (limit != null) {
      query = query.limit(limit);
    }

    final rows = await query;
    return _toMapList(rows);
  }

  Future<Map<String, dynamic>?> getById(String id) async {
    dynamic query = _client.from(tableName).select().eq('id', id);
    if (_isOutletScoped) query = query.eq('outlet_id', _activeOutletId);
    final row = await query.maybeSingle();
    if (row == null) return null;
    return _toMap(row);
  }

  Future<List<Map<String, dynamic>>> getManyByIds(Iterable<String> ids) async {
    final uniqueIds = ids.where((id) => id.trim().isNotEmpty).toSet().toList();
    if (uniqueIds.isEmpty) return [];

    dynamic query = _client.from(tableName).select().inFilter('id', uniqueIds);
    if (_isOutletScoped) query = query.eq('outlet_id', _activeOutletId);
    final rows = await query;
    return _toMapList(rows);
  }

  Future<List<Map<String, dynamic>>> findBy(
    String column,
    Object value, {
    String? orderBy,
    bool ascending = true,
    int? limit,
  }) async {
    dynamic query = _client.from(tableName).select().eq(column, value);
    if (_isOutletScoped) query = query.eq('outlet_id', _activeOutletId);
    if (orderBy != null) {
      query = query.order(orderBy, ascending: ascending);
    }
    if (limit != null) {
      query = query.limit(limit);
    }

    final rows = await query;
    return _toMapList(rows);
  }

  Future<List<Map<String, dynamic>>> findIn(
    String column,
    List<Object> values, {
    String? orderBy,
    bool ascending = true,
    int? limit,
  }) async {
    if (values.isEmpty) return [];
    dynamic query = _client.from(tableName).select().inFilter(column, values);
    if (_isOutletScoped) query = query.eq('outlet_id', _activeOutletId);
    if (orderBy != null) {
      query = query.order(orderBy, ascending: ascending);
    }
    if (limit != null) {
      query = query.limit(limit);
    }

    final rows = await query;
    return _toMapList(rows);
  }

  Future<List<Map<String, dynamic>>> findBetween(
    String column,
    Object startInclusive,
    Object endInclusive, {
    String? orderBy,
    bool ascending = true,
  }) async {
    dynamic query = _client
        .from(tableName)
        .select()
        .gte(column, startInclusive)
        .lte(column, endInclusive);
    if (_isOutletScoped) query = query.eq('outlet_id', _activeOutletId);
    if (orderBy != null) {
      query = query.order(orderBy, ascending: ascending);
    }

    final rows = await query;
    return _toMapList(rows);
  }

  Future<Map<String, dynamic>> create(Map<String, dynamic> values) async {
    final scopedValues = _isOutletScoped
        ? {...values, 'outletId': _activeOutletId}
        : values;
    final row = await _client
        .from(tableName)
        .insert(toSupabaseValues(scopedValues))
        .select()
        .single();
    return _toMap(row);
  }

  /// Updates a row and *verifies* that a row was actually written.
  ///
  /// The previous implementation fired the update without `.select()` and then
  /// re-read the row, returning whatever came back. PostgREST answers an UPDATE
  /// that matches zero rows with `204 No Content` and no error, so an update
  /// blocked by RLS -- or filtered out by the `outlet_id` scope below -- looked
  /// identical to a successful one: the caller got the *old* row back and no
  /// exception. Appointment cancellation and therapist switching both surfaced
  /// as "nothing happened, no error" because of this.
  ///
  /// Using `.select()` makes PostgREST return the updated rows, so an empty
  /// result is an unambiguous signal that nothing matched.
  Future<Map<String, dynamic>> update(
    String id,
    Map<String, dynamic> values,
  ) async {
    final scopedValues = Map<String, dynamic>.from(values);
    if (_isOutletScoped) {
      // Outlet identity scopes the target row; it is not part of an ordinary
      // update. Including it in the payload requires UPDATE privilege on the
      // protected outlet_id column and makes otherwise permitted column-level
      // updates (for example appointment notes) fail before RLS is evaluated.
      scopedValues.remove('outletId');
      scopedValues.remove('outlet_id');
    }
    dynamic query = _client
        .from(tableName)
        .update(toSupabaseValues(scopedValues))
        .eq('id', id);
    if (_isOutletScoped) query = query.eq('outlet_id', _activeOutletId);

    final updated = await query.select();
    final rows = (updated as List).cast<Object?>();

    if (rows.isEmpty) {
      // Distinguish "row is not visible//not in this outlet" from "row exists
      // but the write was rejected", because the two need different fixes.
      final existing = await getById(id);
      if (existing == null) {
        throw StateError(
          'Update to $tableName $id changed no rows: the row does not exist, '
          'is not visible under the current row-level security policy, or '
          'belongs to a different outlet'
          '${_isOutletScoped ? ' (active outlet: $_activeOutletId)' : ''}.',
        );
      }
      throw StateError(
        'Update to $tableName $id changed no rows even though the row is '
        'readable. The write was rejected by row-level security or an outlet '
        'scope mismatch'
        '${_isOutletScoped ? ' (active outlet: $_activeOutletId, row outlet: ${existing['outletId']})' : ''}.',
      );
    }

    return _toMap(rows.first);
  }

  Future<void> delete(String id) async {
    dynamic query = _client.from(tableName).delete().eq('id', id);
    if (_isOutletScoped) query = query.eq('outlet_id', _activeOutletId);
    await query;
  }

  Map<String, dynamic> toSupabaseValues(Map<String, dynamic> values) {
    final normalized = <String, dynamic>{};
    for (final entry in values.entries) {
      if (entry.key == 'id') continue;
      if (entry.key == 'active' && values.containsKey('isActive')) continue;
      if (entry.value == null) continue;
      if (_isSyntheticUuidValue(entry.key, entry.value)) continue;
      normalized[_toSupabaseColumn(entry.key)] = entry.value;
    }
    return normalized;
  }

  bool _isSyntheticUuidValue(String key, Object? value) {
    final uuidKeys = {
      'appointmentId',
      'appointmentGroupId',
      'cashierId',
      'counterId',
      'counterStaffId',
      'createdBy',
      'customerId',
      'outletId',
      'roomId',
      'serviceId',
      'therapistId',
    };
    if (!uuidKeys.contains(key)) return false;
    final text = value?.toString().trim() ?? '';
    return text.isEmpty || text == 'walk_in_guest';
  }

  String _toSupabaseColumn(String key) {
    return _camelToSnakeAliases[key] ?? key;
  }

  Map<String, dynamic> _toMap(Object? row) {
    final raw = Map<String, dynamic>.from(row as Map);
    final normalized = <String, dynamic>{...raw};

    for (final entry in raw.entries) {
      final alias = _snakeToCamelAliases[entry.key];
      if (alias != null && !normalized.containsKey(alias)) {
        normalized[alias] = entry.value;
      }
    }

    if (raw.containsKey('appointment_date') &&
        !normalized.containsKey('date')) {
      normalized['date'] = raw['appointment_date'];
    }

    return normalized;
  }

  List<Map<String, dynamic>> _toMapList(Object? rows) {
    return (rows as List).map((row) => _toMap(row)).toList();
  }
}
