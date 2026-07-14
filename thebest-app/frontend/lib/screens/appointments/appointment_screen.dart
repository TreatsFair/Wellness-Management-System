import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/services/csp_service.dart';
import '../../core/utils/error_message.dart';
import '../../data/repositories/appointment_repository.dart';
import '../../data/repositories/business_settings_repository.dart';
import '../../data/repositories/commission_repository.dart';
import '../../data/repositories/dashboard_repository.dart';
import '../../data/services/supabase_table_service.dart';
import '../booking/booking_screen.dart';

DateTime _stripTime(DateTime date) => DateTime(date.year, date.month, date.day);

int _timeToMinutes(String time) {
  final parts = time.split(':');
  if (parts.length < 2) return 0;
  final hour = int.tryParse(parts[0]) ?? 0;
  final minute = int.tryParse(parts[1]) ?? 0;
  return hour * 60 + minute;
}

String _minutesToTime(int minutes) {
  final normalized = minutes % (24 * 60);
  final hour = (normalized ~/ 60).toString().padLeft(2, '0');
  final minute = (normalized % 60).toString().padLeft(2, '0');
  return '$hour:$minute';
}

String _clockLabel(String time) {
  final minutes = _timeToMinutes(time);
  final hour = (minutes ~/ 60) % 24;
  final minute = minutes % 60;
  return DateFormat('h:mm a').format(DateTime(2026, 1, 1, hour, minute));
}

String _paymentMethodLabel(String value) {
  switch (value.trim().toLowerCase()) {
    case 'qr_code':
      return 'QR Code';
    case 'credit_card':
    case 'card':
      return 'Credit Card';
    case 'debit_card':
      return 'Debit Card';
    case 'cash':
      return 'Cash';
    default:
      return value.trim().isEmpty ? 'Payment recorded' : value.trim();
  }
}

DateTime? _readDateTime(Object? value) {
  final raw = value?.toString().trim() ?? '';
  if (raw.isEmpty) return null;
  return DateTime.tryParse(raw);
}

int? _minutesFromDate(DateTime? value, DateTime baseDate) {
  if (value == null) return null;
  final base = DateTime(baseDate.year, baseDate.month, baseDate.day);
  return value.difference(base).inMinutes;
}

String _durationLabel(int minutes) {
  final safe = minutes.clamp(0, 24 * 60);
  if (safe < 60) return '$safe mins';
  final hours = safe ~/ 60;
  final mins = safe % 60;
  if (mins == 0) return hours == 1 ? '1 hr' : '$hours hrs';
  return '${hours}h ${mins}m';
}

String _genderLabel(String value) {
  final normalized = value.trim().toLowerCase();
  if (normalized == 'f' || normalized == 'female') return 'Female';
  if (normalized == 'm' || normalized == 'male') return 'Male';
  return value.trim();
}

String _hourLabel(int hour) {
  final normalized = hour % 24;
  final displayHour = normalized == 0
      ? 12
      : normalized > 12
      ? normalized - 12
      : normalized;
  return '$displayHour${normalized < 12 ? 'am' : 'pm'}';
}

double _readDouble(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value) ?? 0;
  return 0;
}

int _readInt(Object? value, [int fallback = 0]) {
  if (value is int) return value;
  if (value is num) return value.round();
  if (value is String) return int.tryParse(value) ?? fallback;
  return fallback;
}

String _generateReceiptNumber() {
  final now = DateTime.now();
  return 'TXN-${DateFormat('yyyyMMdd').format(now)}-'
      '${now.millisecondsSinceEpoch.toString().substring(8)}';
}

class _ScheduleAppointment {
  final String id;
  final String appointmentGroupId;
  final String customerId;
  final String dateKey;
  final DateTime date;
  final String startTime;
  final String endTime;
  final DateTime? startAt;
  final DateTime? endAt;
  final String bookedDateKey;
  final String bookedStartTime;
  final String bookedEndTime;
  final DateTime? actualStartedAt;
  final int bufferAfterMinutes;
  final String status;
  final String type;
  final String customerName;
  final String customerPhone;
  final String customerGender;
  final String serviceId;
  final String serviceName;
  final String serviceDescription;
  final String therapistId;
  final String therapistName;
  final String roomId;
  final String roomName;
  final String notes;
  final double price;
  final String receiptNumber;
  final String paymentMethod;
  final String paymentStatus;
  final double paidAmount;
  final List<Map<String, dynamic>> serviceItems;
  final Map<String, dynamic> therapistCommissionData;
  final int lateGraceMinutes;
  final int delayWarningMinutes;

  const _ScheduleAppointment({
    required this.id,
    required this.appointmentGroupId,
    required this.customerId,
    required this.dateKey,
    required this.date,
    required this.startTime,
    required this.endTime,
    required this.startAt,
    required this.endAt,
    required this.bookedDateKey,
    required this.bookedStartTime,
    required this.bookedEndTime,
    required this.actualStartedAt,
    required this.bufferAfterMinutes,
    required this.status,
    required this.type,
    required this.customerName,
    required this.customerPhone,
    required this.customerGender,
    required this.serviceId,
    required this.serviceName,
    required this.serviceDescription,
    required this.therapistId,
    required this.therapistName,
    required this.roomId,
    required this.roomName,
    required this.notes,
    required this.price,
    required this.receiptNumber,
    required this.paymentMethod,
    required this.paymentStatus,
    required this.paidAmount,
    required this.serviceItems,
    required this.therapistCommissionData,
    required this.lateGraceMinutes,
    required this.delayWarningMinutes,
  });

  factory _ScheduleAppointment.fromMap(
    Map<String, dynamic> data, {
    required Map<String, Map<String, dynamic>> customers,
    required Map<String, Map<String, dynamic>> services,
    required Map<String, Map<String, dynamic>> therapists,
    required Map<String, Map<String, dynamic>> rooms,
    Map<String, dynamic>? transaction,
    required int lateGraceMinutes,
    required int delayWarningMinutes,
  }) {
    final customerId = data['customerId']?.toString() ?? '';
    final customer = customers[customerId];
    final serviceId = data['serviceId']?.toString() ?? '';
    final therapistId = data['therapistId']?.toString() ?? '';
    final roomId = data['roomId']?.toString() ?? '';
    final service = services[serviceId];
    final therapist = therapists[therapistId];
    final room = rooms[roomId];
    final dateKey = _readDateKey(data['date']);
    final isGuestCustomer =
        customerId.trim().isEmpty || customerId == 'walk_in_guest';
    final rawCustomerName =
        data['customerName']?.toString() ?? customer?['name']?.toString();
    final customerName = isGuestCustomer && _isGuestName(rawCustomerName)
        ? 'Guest'
        : rawCustomerName ?? 'Customer';

    return _ScheduleAppointment(
      id: data['id']?.toString() ?? '',
      appointmentGroupId: data['appointmentGroupId']?.toString() ?? '',
      customerId: customerId,
      dateKey: dateKey,
      date: _readDate(dateKey, data['date']),
      startTime: data['startTime']?.toString() ?? '09:00',
      endTime: data['endTime']?.toString() ?? '10:00',
      startAt: _readDateTime(data['startAt']),
      endAt: _readDateTime(data['endAt']),
      bookedDateKey:
          data['bookedDate']?.toString() ?? data['date']?.toString() ?? dateKey,
      bookedStartTime:
          data['bookedStartTime']?.toString() ??
          data['startTime']?.toString() ??
          '09:00',
      bookedEndTime:
          data['bookedEndTime']?.toString() ??
          data['endTime']?.toString() ??
          '10:00',
      actualStartedAt: _readDateTime(data['actualStartedAt']),
      bufferAfterMinutes: _readInt(data['bufferAfterMinutes'], 0),
      status: data['status']?.toString().trim().toLowerCase() ?? 'pending',
      type: data['type']?.toString().trim().toLowerCase() ?? '',
      customerName: customerName,
      customerPhone:
          data['customerPhone']?.toString() ??
          customer?['phone']?.toString() ??
          '-',
      customerGender: _genderLabel(
        data['customerGender']?.toString() ??
            data['gender']?.toString() ??
            customer?['gender']?.toString() ??
            '',
      ),
      serviceId: serviceId,
      serviceName:
          data['serviceName']?.toString() ??
          service?['name']?.toString() ??
          'Service',
      serviceDescription:
          data['serviceDescription']?.toString() ??
          service?['description']?.toString() ??
          'Wellness treatment',
      therapistId: therapistId,
      therapistName:
          data['therapistName']?.toString() ??
          therapist?['name']?.toString() ??
          'Unassigned',
      roomId: roomId,
      roomName:
          data['roomName']?.toString() ?? room?['name']?.toString() ?? 'Room',
      notes: data['notes']?.toString() ?? '',
      price: _readDouble(data['totalPrice'] ?? data['price']),
      receiptNumber: transaction?['receiptNumber']?.toString() ?? '',
      paymentMethod: transaction?['paymentMethod']?.toString() ?? '',
      // Authoritative payment state now lives on the appointment row itself
      // (043), kept in sync from transactions by trigger. Reading it here
      // instead of inferring "paid" from whether a transaction row happened to
      // join fixes paid online bookings that used to show as Payment Pending.
      paymentStatus: data['paymentStatus']?.toString() ?? 'unpaid',
      paidAmount: _readDouble(transaction?['totalAmount']),
      serviceItems: _readServiceItems(
        data['serviceItems'],
        serviceId: serviceId,
        serviceName:
            data['serviceName']?.toString() ??
            service?['name']?.toString() ??
            'Service',
        service: service,
        fallbackPrice: _readDouble(data['totalPrice'] ?? data['price']),
      ),
      therapistCommissionData: {
        'id': therapistId,
        'name': therapist?['name'],
        'serviceCommissions': therapist?['serviceCommissions'],
      },
      lateGraceMinutes: lateGraceMinutes,
      delayWarningMinutes: delayWarningMinutes,
    );
  }

  static List<Map<String, dynamic>> _readServiceItems(
    Object? value, {
    required String serviceId,
    required String serviceName,
    required Map<String, dynamic>? service,
    required double fallbackPrice,
  }) {
    if (value is List && value.isNotEmpty) {
      return value.whereType<Map>().map((item) {
        final data = Map<String, dynamic>.from(item);
        final itemId =
            data['id']?.toString() ?? data['serviceId']?.toString() ?? '';
        final linkedService = itemId == serviceId ? service : null;
        return {
          ...data,
          'id': itemId,
          'name':
              data['name']?.toString() ??
              linkedService?['name']?.toString() ??
              serviceName,
          'duration': _readInt(
            data['duration'] ?? linkedService?['duration'],
            60,
          ),
          'bufferAfterMinutes': _readInt(
            data['bufferAfterMinutes'] ?? linkedService?['bufferAfterMinutes'],
            0,
          ),
          'price': _readDouble(data['price'] ?? linkedService?['price']),
          'therapistCommission': _readDouble(
            data['therapistCommission'] ??
                linkedService?['therapistCommission'],
          ),
          'counterCommission': _readDouble(
            data['counterCommission'] ?? linkedService?['counterCommission'],
          ),
        };
      }).toList();
    }

    return [
      {
        'id': serviceId,
        'name': serviceName,
        'duration': _readInt(service?['duration'], 60),
        'bufferAfterMinutes': _readInt(service?['bufferAfterMinutes'], 0),
        'price': fallbackPrice > 0
            ? fallbackPrice
            : _readDouble(service?['price']),
        'therapistCommission': _readDouble(service?['therapistCommission']),
        'counterCommission': _readDouble(service?['counterCommission']),
      },
    ];
  }

  static String _readDateKey(Object? value) {
    final raw = value?.toString().trim() ?? '';
    if (raw.isEmpty) return DateFormat('yyyy-MM-dd').format(DateTime.now());
    return raw.length >= 10 ? raw.substring(0, 10) : raw;
  }

  static DateTime _readDate(String dateKey, Object? value) {
    return DateTime.tryParse(dateKey) ?? _stripTime(DateTime.now());
  }

  static bool _isGuestName(Object? value) {
    final normalized = value?.toString().trim().toLowerCase() ?? '';
    return normalized.isEmpty ||
        normalized == 'guest' ||
        normalized == 'guest account' ||
        normalized == 'walk-in guest';
  }

  int get startMinutes {
    return _minutesFromDate(startAt, date) ?? _timeToMinutes(startTime);
  }

  int get endMinutes {
    final timestampMinutes = _minutesFromDate(endAt, date);
    if (timestampMinutes != null) return timestampMinutes;
    final start = _timeToMinutes(startTime);
    var end = _timeToMinutes(endTime);
    if (end <= start) end += 24 * 60;
    return end;
  }

  int get hour => startMinutes ~/ 60;
  int get durationMinutes => (endMinutes - startMinutes).clamp(0, 1440);
  int get bookedStartMinutes => _timeToMinutes(bookedStartTime);
  int get bookedEndMinutes {
    final start = bookedStartMinutes;
    var end = _timeToMinutes(bookedEndTime);
    if (end <= start) end += 24 * 60;
    return end;
  }
  int get scheduledServiceMinutes {
    final booked = bookedEndMinutes - bookedStartMinutes;
    return booked > 0 ? booked.clamp(0, 1440) : durationMinutes;
  }
  int get cleanupEndMinutes => endMinutes + bufferAfterMinutes.clamp(0, 240);
  int get blockDurationMinutes =>
      (cleanupEndMinutes - startMinutes).clamp(0, 1440);
  String get displayStartTime =>
      !isWalkIn && hasActualTiming ? bookedStartTime : startTime;
  String get displayEndTime =>
      !isWalkIn && hasActualTiming ? bookedEndTime : endTime;
  int get displayDurationMinutes =>
      !isWalkIn && hasActualTiming ? scheduledServiceMinutes : durationMinutes;
  String get startLabel => _clockLabel(displayStartTime);
  String get endLabel => _clockLabel(displayEndTime);
  String get timeRange => '$startLabel - $endLabel';
  String get cleanupUntilLabel => bufferAfterMinutes <= 0
      ? 'No cleanup buffer'
      : 'Cleanup until ${_clockLabel(_minutesToTime(cleanupEndMinutes))} '
            '(+$bufferAfterMinutes min)';
  String get blockDurationLabel => bufferAfterMinutes <= 0
      ? '$timeRange ($durationMinutes min)'
      : '$timeRange ($durationMinutes min) + $bufferAfterMinutes min cleanup';
  String get bookedTimeRange =>
      '${_clockLabel(bookedStartTime)} - ${_clockLabel(bookedEndTime)}';
  bool get hasActualTiming => actualStartedAt != null;
  DateTime? get actualServiceEndAt => actualStartedAt
      ?.toLocal()
      .add(Duration(minutes: scheduledServiceMinutes));
  String get actualServiceTimeRange {
    final started = actualStartedAt?.toLocal();
    final ended = actualServiceEndAt;
    if (started == null || ended == null) return '';
    return '${DateFormat('h:mm a').format(started)} - '
        '${DateFormat('h:mm a').format(ended)} '
        '(${_durationLabel(scheduledServiceMinutes)})';
  }
  String? get actualServiceCompletionLabel => null;
  String get priceLabel => 'RM ${price.toStringAsFixed(0)}';
  String get servicePriceLabel => '$serviceName - $priceLabel';
  bool get isCancelled => status == 'cancelled' || status == 'canceled';

  bool get isWalkIn {
    return type == 'walkin' ||
        type == 'walk_in' ||
        type == 'walk-in' ||
        customerId == 'walk_in_guest';
  }

  /// Real-world moment this service is scheduled to start.
  DateTime get _serviceStartDateTime {
    final resolved = startAt?.toLocal();
    if (resolved != null) return resolved;
    return DateTime(
      date.year,
      date.month,
      date.day,
    ).add(Duration(minutes: startMinutes));
  }

  /// Real-world moment this service is scheduled to finish.
  DateTime get _serviceEndDateTime {
    final actualEnd = actualServiceEndAt;
    if (actualEnd != null) return actualEnd;
    final resolved = endAt?.toLocal();
    if (resolved != null) return resolved;
    return DateTime(
      date.year,
      date.month,
      date.day,
    ).add(Duration(minutes: endMinutes));
  }

  bool get serviceWindowEnded => DateTime.now().isAfter(_serviceEndDateTime);
  bool get isServiceDateToday => _stripTime(date) == _stripTime(DateTime.now());
  // Staff may check a customer in up to 30 minutes before the scheduled start
  // (early arrival). Mirrors the server guard in migration 050.
  bool get isServiceStartDue => !DateTime.now().isBefore(
    _serviceStartDateTime.subtract(const Duration(minutes: 30)),
  );
  bool get missedServiceWindow =>
      !isWalkIn &&
      !hasActualTiming &&
      serviceWindowEnded &&
      (status == 'confirmed' || status == 'pending');
  bool get isNoShow => status == 'no_show';

  bool get isCompleted {
    if (isCancelled || isNoShow) return false;
    if (status == 'completed') return true;
    // Paid services auto-complete once their booked window has passed after
    // check-in/start. Walk-ins keep their original automatic completion rule.
    return (status == 'in_progress' || isWalkIn) &&
        hasPayment &&
        serviceWindowEnded;
  }

  bool get isInProgress {
    if (isCancelled || isNoShow || isCompleted) return false;
    // A paid walk-in is the service happening now, until its window ends.
    if (isWalkIn) return hasPayment;
    return status == 'in_progress';
  }

  bool get isPending =>
      !isCompleted && !isInProgress && !isCancelled && !isNoShow;
  // Staff only need to confirm payment or check in; completion is automatic.
  bool get canAdvance =>
      isPending && !isWalkIn && isServiceDateToday && isServiceStartDue;
  // payment_status on the appointment (043) is the single source of truth.
  bool get hasPayment => paymentStatus.toLowerCase() == 'paid';
  bool get isRefunded => paymentStatus.toLowerCase() == 'refunded';
  bool get isAwaiting => isPending && hasPayment && !isWalkIn;
  String get durationLabel => _durationLabel(displayDurationMinutes);
  bool get isGuestAccount =>
      customerId.trim().isEmpty || customerId == 'walk_in_guest';

  bool get shouldTrackArrivalDelay =>
      !isWalkIn &&
      !isCancelled &&
      !isNoShow &&
      !isCompleted &&
      !isInProgress &&
      actualStartedAt == null &&
      (status == 'confirmed' || status == 'pending');

  int get arrivalDelayMinutes {
    if (!shouldTrackArrivalDelay) return 0;
    final delay = DateTime.now().difference(_serviceStartDateTime).inMinutes;
    return delay < 0 ? 0 : delay;
  }

  bool get hasDelayWarning =>
      delayWarningMinutes > 0 && arrivalDelayMinutes >= delayWarningMinutes;
  bool get isLateArrival =>
      lateGraceMinutes > 0 && arrivalDelayMinutes > lateGraceMinutes;

  String get arrivalDelayLabel {
    final minutes = arrivalDelayMinutes;
    if (minutes <= 0) return '';
    if (isLateArrival) return 'Late $minutes min';
    if (hasDelayWarning) return 'Delayed $minutes min';
    return '';
  }

  String get statusLabel {
    if (isCompleted) return 'Completed';
    if (isInProgress) return 'In Progress';
    if (isCancelled) return 'Cancelled';
    if (isNoShow) return 'No Show';
    if (arrivalDelayLabel.isNotEmpty) return arrivalDelayLabel;
    return isAwaiting ? 'Awaiting' : 'Payment Pending';
  }

  String get paymentStatusLabel {
    switch (paymentStatus.toLowerCase()) {
      case 'paid':
        return 'Paid';
      case 'refunded':
        return 'Refunded';
      case 'voided':
        return 'Voided';
      default:
        return 'Unpaid';
    }
  }

  String get initials {
    final parts = customerName.trim().split(RegExp(r'\s+'));
    if (parts.length >= 2) {
      return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
    }
    return customerName.isEmpty ? '?' : customerName[0].toUpperCase();
  }

  bool matches(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return customerName.toLowerCase().contains(q) ||
        customerPhone.toLowerCase().contains(q) ||
        serviceName.toLowerCase().contains(q) ||
        therapistName.toLowerCase().contains(q) ||
        roomName.toLowerCase().contains(q);
  }

  int lateMinutesAt(DateTime startedAt) {
    final delay = startedAt.difference(_serviceStartDateTime).inMinutes;
    return delay < 0 ? 0 : delay;
  }

  DateTime extendedEndForStart(DateTime startedAt) {
    return startedAt.add(Duration(minutes: scheduledServiceMinutes));
  }

  Map<String, dynamic> serviceStartUpdates(
    DateTime startedAt, {
    DateTime? adjustedEndAt,
    bool allowLateExtensionOverlap = false,
  }) {
    final localAdjustedEnd = adjustedEndAt?.toLocal();
    return {
      'bookedDate': bookedDateKey,
      'bookedStartTime': bookedStartTime,
      'bookedEndTime': bookedEndTime,
      if (startAt != null) 'bookedStartAt': startAt!.toUtc().toIso8601String(),
      if (endAt != null) 'bookedEndAt': endAt!.toUtc().toIso8601String(),
      if (localAdjustedEnd != null)
        'endTime': DateFormat('HH:mm:ss').format(localAdjustedEnd),
      if (adjustedEndAt != null)
        'endAt': adjustedEndAt.toUtc().toIso8601String(),
      'actualStartedAt': startedAt.toUtc().toIso8601String(),
      'allowLateExtensionOverlap': allowLateExtensionOverlap,
    };
  }
}

class _AppointmentGroup {
  final String id;
  final String appointmentGroupId;
  final List<_ScheduleAppointment> appointments;

  const _AppointmentGroup({
    required this.id,
    required this.appointmentGroupId,
    required this.appointments,
  });

  _ScheduleAppointment get primary => appointments.first;
  bool get isGroup => appointmentGroupId.isNotEmpty && appointments.length > 1;
  int get paxCount => appointments.length;
  DateTime get date => primary.date;
  String get dateKey => primary.dateKey;
  String get customerName => primary.customerName;
  String get customerPhone => primary.customerPhone;
  String get customerGender => primary.customerGender;
  String get initials => primary.initials;
  bool get isGuestAccount => primary.isGuestAccount;
  bool get isCancelled => appointments.every((a) => a.isCancelled);
  bool get isNoShow => appointments.every((a) => a.isNoShow);
  bool get isCompleted => appointments.every((a) => a.isCompleted);
  bool get isInProgress => appointments.any((a) => a.isInProgress);
  bool get isPending =>
      !isCompleted && !isInProgress && !isCancelled && !isNoShow;
  // Staff only need to confirm payment or check in; completion is automatic.
  bool get canAdvance =>
      isPending &&
      !primary.isWalkIn &&
      primary.isServiceDateToday &&
      primary.isServiceStartDue;
  bool get hasPayment => primary.hasPayment;
  bool get isRefunded => primary.isRefunded;
  bool get isAwaiting => appointments.any((a) => a.isAwaiting);
  int get arrivalDelayMinutes => appointments.fold<int>(
    0,
    (max, appointment) => appointment.arrivalDelayMinutes > max
        ? appointment.arrivalDelayMinutes
        : max,
  );
  bool get hasDelayWarning => appointments.any((a) => a.hasDelayWarning);
  bool get isLateArrival => appointments.any((a) => a.isLateArrival);
  String get arrivalDelayLabel {
    final minutes = arrivalDelayMinutes;
    if (minutes <= 0) return '';
    if (isLateArrival) return 'Late $minutes min';
    if (hasDelayWarning) return 'Delayed $minutes min';
    return '';
  }
  String get receiptNumber => primary.receiptNumber;
  String get paymentMethod => primary.paymentMethod;
  String get paymentStatus => primary.paymentStatus;
  String get paymentStatusLabel => primary.paymentStatusLabel;
  double get paidAmount => primary.paidAmount;
  String get statusLabel => isCompleted
      ? 'Completed'
      : isInProgress
      ? 'In Progress'
      : isCancelled
      ? 'Cancelled'
      : isNoShow
      ? 'No Show'
      : arrivalDelayLabel.isNotEmpty
      ? arrivalDelayLabel
      : isAwaiting
      ? 'Awaiting'
      : 'Payment Pending';
  String get durationLabel => _durationLabel(durationMinutes);

  int get startMinutes =>
      appointments.map((a) => a.startMinutes).reduce((a, b) => a < b ? a : b);
  int get endMinutes =>
      appointments.map((a) => a.endMinutes).reduce((a, b) => a > b ? a : b);
  int get cleanupEndMinutes => appointments
      .map((a) => a.cleanupEndMinutes)
      .reduce((a, b) => a > b ? a : b);
  int get durationMinutes => (endMinutes - startMinutes).clamp(0, 1440);
  int get blockDurationMinutes =>
      (cleanupEndMinutes - startMinutes).clamp(0, 1440);
  String get timeRange =>
      '${_clockLabel(_minutesToTime(startMinutes))} - ${_clockLabel(_minutesToTime(endMinutes))}';
  String get cleanupUntilLabel =>
      'Cleanup until ${_clockLabel(_minutesToTime(cleanupEndMinutes))}';
  String get blockDurationLabel =>
      '$timeRange ($durationMinutes min) + cleanup block until ${_clockLabel(_minutesToTime(cleanupEndMinutes))}';
  double get price => appointments.fold(0, (total, a) => total + a.price);
  String get priceLabel => 'RM ${price.toStringAsFixed(0)}';

  String get serviceName {
    if (!isGroup) return primary.serviceName;
    return '$paxCount pax services';
  }

  String get serviceDescription {
    if (!isGroup) return primary.serviceDescription;
    return '${appointments.length} service allocations';
  }

  String get servicePriceLabel {
    if (!isGroup) return primary.servicePriceLabel;
    return '$serviceName - $priceLabel';
  }

  String get therapistName {
    if (!isGroup) return primary.therapistName;
    final count = appointments
        .map((a) => a.therapistId.isNotEmpty ? a.therapistId : a.therapistName)
        .toSet()
        .length;
    return '$count staff assigned';
  }

  String get roomName {
    if (!isGroup) return primary.roomName;
    final count = appointments
        .map((a) => a.roomId.isNotEmpty ? a.roomId : a.roomName)
        .toSet()
        .length;
    return '$count resources';
  }

  List<Map<String, dynamic>> get serviceItems {
    final items = <Map<String, dynamic>>[];
    for (var index = 0; index < appointments.length; index++) {
      final appointment = appointments[index];
      for (final item in appointment.serviceItems) {
        items.add({
          ...item,
          'paxIndex': index + 1,
          'paxLabel': 'Pax ${index + 1}',
          'paxCustomerName': appointment.customerName,
          'assignedTherapistId':
              item['assignedTherapistId'] ?? appointment.therapistId,
          'assignedTherapistName':
              item['assignedTherapistName'] ?? appointment.therapistName,
          'assignedRoomId': item['assignedRoomId'] ?? appointment.roomId,
          'assignedRoomName': item['assignedRoomName'] ?? appointment.roomName,
        });
      }
    }
    return items;
  }

  bool matches(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return appointments.any((a) => a.matches(q));
  }
}

class _LateStartDecision {
  const _LateStartDecision({
    this.adjustedEndAt,
    this.allowLateExtensionOverlap = false,
  });

  final DateTime? adjustedEndAt;
  final bool allowLateExtensionOverlap;
}

Future<_LateStartDecision> _lateStartDecision({
  required BuildContext context,
  required _ScheduleAppointment appointment,
  required BusinessRuleSettings settings,
  required DateTime startedAt,
}) async {
  if (!settings.autoExtendLateArrivals) {
    return const _LateStartDecision();
  }

  final lateMinutes = appointment.lateMinutesAt(startedAt);
  if (lateMinutes <= 0 || lateMinutes > settings.lateGraceMinutes) {
    return const _LateStartDecision();
  }

  final adjustedEnd = appointment.extendedEndForStart(startedAt);
  if (!adjustedEnd.isAfter(appointment._serviceEndDateTime)) {
    return const _LateStartDecision();
  }

  final availability = await CspService.validateSlot(
    date: appointment.dateKey,
    startTime: appointment.startTime,
    endTime: DateFormat('HH:mm:ss').format(adjustedEnd.toLocal()),
    therapistId: appointment.therapistId,
    roomId: appointment.roomId,
    excludeId: appointment.id,
  );

  if (availability.therapistAvailable && !availability.roomFull) {
    return _LateStartDecision(adjustedEndAt: adjustedEnd);
  }

  if (!context.mounted) return const _LateStartDecision();
  final extendAnyway = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Extend service time?'),
      content: Text(
        '${appointment.customerName} arrived $lateMinutes minutes late. '
        'Keeping the full ${appointment.durationMinutes}-minute service will overlap another booking or room capacity.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Start without extending'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('Extend anyway'),
        ),
      ],
    ),
  );

  if (extendAnyway == true) {
    return _LateStartDecision(
      adjustedEndAt: adjustedEnd,
      allowLateExtensionOverlap: true,
    );
  }
  return const _LateStartDecision();
}

class _AppointmentTherapist {
  final String id;
  final String name;
  final String role;
  final bool available;

  const _AppointmentTherapist({
    required this.id,
    required this.name,
    required this.role,
    required this.available,
  });

  factory _AppointmentTherapist.fromMap(Map<String, dynamic> row) {
    return _AppointmentTherapist(
      id: row['id']?.toString() ?? '',
      name: row['name']?.toString() ?? 'Therapist',
      role: row['role']?.toString() ?? 'Therapist',
      available: _readBool(row['availabilityStatus'], true),
    );
  }

  String get initials {
    final parts = name
        .trim()
        .split(RegExp(r'\s+'))
        .where((part) => part.isNotEmpty)
        .toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first[0].toUpperCase();
    return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
  }
}

bool _readBool(Object? value, [bool fallback = false]) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) {
    final normalized = value.trim().toLowerCase();
    if (normalized == 'true' || normalized == 'yes' || normalized == '1') {
      return true;
    }
    if (normalized == 'false' || normalized == 'no' || normalized == '0') {
      return false;
    }
  }
  return fallback;
}

List<_AppointmentTherapist> _buildAppointmentTherapists(
  List<Map<String, dynamic>> rows,
  List<_ScheduleAppointment> appointments,
) {
  final therapists = rows
      .where((row) {
        final role = row['role']?.toString().toLowerCase() ?? 'therapist';
        return role.contains('therapist');
      })
      .map(_AppointmentTherapist.fromMap)
      .toList()
    ..sort((a, b) => a.name.compareTo(b.name));

  final knownIds = therapists.map((therapist) => therapist.id).toSet();
  for (final appointment in appointments) {
    if (appointment.therapistId.isEmpty ||
        knownIds.contains(appointment.therapistId)) {
      continue;
    }
    knownIds.add(appointment.therapistId);
    therapists.add(
      _AppointmentTherapist(
        id: appointment.therapistId,
        name: appointment.therapistName,
        role: 'Therapist',
        available: true,
      ),
    );
  }
  return therapists;
}

class AppointmentsScreen extends StatefulWidget {
  final String userRole;

  const AppointmentsScreen({super.key, required this.userRole});

  @override
  State<AppointmentsScreen> createState() => _AppointmentsScreenState();
}

class _AppointmentsScreenState extends State<AppointmentsScreen> {
  final _appointmentRepository = AppointmentRepository();
  final _dashboardRepository = DashboardRepository();
  final _businessSettingsTable = SupabaseTableService('business_settings');
  final _transactionTable = SupabaseTableService('transactions');

  late DateTime _selectedDate;
  late DateTime _windowStart;
  final _searchController = TextEditingController();
  List<_ScheduleAppointment> _appointments = [];
  List<_AppointmentTherapist> _therapists = [];
  _AppointmentGroup? _selectedGroup;
  bool _showTabletTimeline = false;
  int _openHour = 9;
  int _closeHour = 21;
  BusinessRuleSettings _businessRuleSettings = BusinessRuleSettings.defaults();
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _selectedDate = _stripTime(DateTime.now());
    _windowStart = _windowStartFor(_selectedDate);
    _searchController.addListener(() => setState(() {}));
    _loadAppointments();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  // The day strip shows a 6-day window with the selected day second, so the
  // user sees one day of context before and four days ahead.
  static DateTime _windowStartFor(DateTime date) =>
      _stripTime(date).subtract(const Duration(days: 1));

  String _dateKey(DateTime date) => DateFormat('yyyy-MM-dd').format(date);

  int _parseBusinessMinutes(Object? value, int fallback) {
    final raw = value?.toString().trim() ?? '';
    final parts = raw.split(':');
    if (parts.length < 2) return fallback;
    final hour = int.tryParse(parts[0]);
    final minute = int.tryParse(parts[1]);
    if (hour == null || minute == null) return fallback;
    return hour * 60 + minute;
  }

  Future<void> _loadBusinessHours() async {
    try {
      final rows = await _businessSettingsTable.list(limit: 1);
      final row = rows.isEmpty ? null : rows.first;
      final rules = row == null
          ? BusinessRuleSettings.defaults()
          : BusinessRuleSettings.fromMap(row);
      final openMinutes = _parseBusinessMinutes(row?['openTime'], 9 * 60);
      var closeMinutes = _parseBusinessMinutes(row?['closeTime'], 21 * 60);
      if (closeMinutes <= openMinutes) closeMinutes += 24 * 60;
      final open = openMinutes ~/ 60;
      final close = (closeMinutes / 60).ceil();
      if (!mounted) return;
      setState(() {
        _openHour = open;
        _closeHour = close;
        _businessRuleSettings = rules;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _openHour = 9;
        _closeHour = 21;
        _businessRuleSettings = BusinessRuleSettings.defaults();
      });
    }
  }

  List<DateTime> get _visibleDays =>
      List.generate(6, (index) => _windowStart.add(Duration(days: index)));

  List<_AppointmentGroup> get _appointmentGroups {
    final byGroup = <String, List<_ScheduleAppointment>>{};
    for (final appointment in _appointments) {
      final key = appointment.appointmentGroupId.isNotEmpty
          ? appointment.appointmentGroupId
          : appointment.id;
      byGroup.putIfAbsent(key, () => []).add(appointment);
    }

    final groups =
        byGroup.entries.map((entry) {
          final items = entry.value
            ..sort((a, b) {
              final start = a.startMinutes.compareTo(b.startMinutes);
              if (start != 0) return start;
              return a.customerName.compareTo(b.customerName);
            });
          final groupId = items.first.appointmentGroupId;
          return _AppointmentGroup(
            id: entry.key,
            appointmentGroupId: groupId,
            appointments: items,
          );
        }).toList()..sort((a, b) {
          final dateCompare = a.dateKey.compareTo(b.dateKey);
          if (dateCompare != 0) return dateCompare;
          return a.startMinutes.compareTo(b.startMinutes);
        });
    return groups;
  }

  List<_AppointmentGroup> get _filteredGroups {
    return _appointmentGroups
        .where((group) => group.matches(_searchController.text))
        .toList();
  }

  List<_AppointmentGroup> get _selectedDayGroups {
    final key = _dateKey(_selectedDate);
    final list = _filteredGroups.where((a) => a.dateKey == key).toList();
    list.sort((a, b) => a.startMinutes.compareTo(b.startMinutes));
    return list;
  }

  List<_ScheduleAppointment> _appointmentsForDay(DateTime date) {
    final key = _dateKey(date);
    return _appointmentGroups
        .where((group) => group.dateKey == key)
        .map((group) => group.primary)
        .toList();
  }

  int get _pendingCount => _selectedDayGroups.where((a) => a.isPending).length;

  int get _inProgressCount =>
      _selectedDayGroups.where((a) => a.isInProgress).length;

  int get _completedCount =>
      _selectedDayGroups.where((a) => a.isCompleted).length;

  double get _selectedDaySales =>
      _selectedDayGroups.fold<double>(0, (total, group) => total + group.price);

  Future<void> _loadAppointments() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      await _loadBusinessHours();
      await _appointmentRepository.completeDueAppointments();
      await _appointmentRepository.markPastAppointmentsNoShow();
      final startKey = _dateKey(_windowStart);
      final endKey = _dateKey(_windowStart.add(const Duration(days: 6)));
      final appointmentRows = await _appointmentRepository
          .getAppointmentsInDateRange(startKey, endKey);
      final appointmentIds = appointmentRows
          .map((data) => data['id']?.toString() ?? '')
          .where((id) => id.isNotEmpty)
          .toSet()
          .toList();
      final appointmentGroupIds = appointmentRows
          .map((data) => data['appointmentGroupId']?.toString() ?? '')
          .where((id) => id.isNotEmpty)
          .toSet()
          .toList();
      final transactionResults = await Future.wait([
        _transactionTable.findIn(
          'appointment_id',
          appointmentIds.cast<Object>(),
        ),
        _transactionTable.findIn(
          'appointment_group_id',
          appointmentGroupIds.cast<Object>(),
        ),
      ]);
      final transactionsByAppointment = <String, Map<String, dynamic>>{};
      final transactionsByGroup = <String, Map<String, dynamic>>{};
      for (final transaction in [
        ...transactionResults[0],
        ...transactionResults[1],
      ]) {
        final appointmentId = transaction['appointmentId']?.toString() ?? '';
        final groupId = transaction['appointmentGroupId']?.toString() ?? '';
        if (appointmentId.isNotEmpty) {
          transactionsByAppointment[appointmentId] = transaction;
        }
        if (groupId.isNotEmpty) transactionsByGroup[groupId] = transaction;
      }
      final customerIds = appointmentRows
          .map((data) => data['customerId']?.toString() ?? '')
          .where((id) => id.isNotEmpty);
      final serviceIds = appointmentRows
          .map((data) => data['serviceId']?.toString() ?? '')
          .where((id) => id.isNotEmpty);
      final therapistIds = appointmentRows
          .map((data) => data['therapistId']?.toString() ?? '')
          .where((id) => id.isNotEmpty);
      final roomIds = appointmentRows
          .map((data) => data['roomId']?.toString() ?? '')
          .where((id) => id.isNotEmpty);

      final customers = await _dashboardRepository.loadByIds(
        'customers',
        customerIds,
      );
      final services = await _dashboardRepository.loadByIds(
        'services',
        serviceIds,
      );
      final therapistRows = await _dashboardRepository.listTherapists();
      final allTherapists = {
        for (final row in therapistRows) row['id']?.toString() ?? '': row,
      };
      allTherapists.remove('');
      final linkedTherapists = await _dashboardRepository.loadByIds(
        'therapists',
        therapistIds.where((id) => !allTherapists.containsKey(id)),
      );
      final therapists = {...allTherapists, ...linkedTherapists};
      final rooms = await _dashboardRepository.loadByIds('rooms', roomIds);

      final appointments =
          appointmentRows
              .where((data) {
                final type = data['type']?.toString().trim().toLowerCase();
                return type == null ||
                    type.isEmpty ||
                    type == 'appointment' ||
                    type == 'online';
              })
              .map(
                (data) => _ScheduleAppointment.fromMap(
                  data,
                  customers: customers,
                  services: services,
                  therapists: therapists,
                  rooms: rooms,
                  transaction:
                      transactionsByAppointment[data['id']?.toString()] ??
                      transactionsByGroup[data['appointmentGroupId']
                          ?.toString()],
                  lateGraceMinutes: _businessRuleSettings.lateGraceMinutes,
                  delayWarningMinutes:
                      _businessRuleSettings.delayWarningMinutes,
                ),
              )
              .where((appointment) => !appointment.isCancelled)
              .toList()
            ..sort((a, b) {
              final dateCompare = a.dateKey.compareTo(b.dateKey);
              if (dateCompare != 0) return dateCompare;
              return a.startMinutes.compareTo(b.startMinutes);
            });

      if (!mounted) return;
      setState(() {
        _appointments = appointments;
        _therapists = _buildAppointmentTherapists(therapistRows, appointments);
        if (_selectedGroup != null) {
          final matches = _appointmentGroups
              .where((group) => group.id == _selectedGroup!.id)
              .toList();
          _selectedGroup = matches.isEmpty ? null : matches.first;
        }
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _moveDays(int days) {
    setState(() {
      _windowStart = _windowStart.add(Duration(days: days));
      _selectedDate = _selectedDate.add(Duration(days: days));
      _selectedGroup = null;
    });
    _loadAppointments();
  }

  Future<void> _openCalendarPicker() async {
    final picked = await showDialog<DateTime>(
      context: context,
      builder: (context) => _MonthCalendarDialog(initialDate: _selectedDate),
    );
    if (picked == null) return;

    setState(() {
      _selectedDate = _stripTime(picked);
      _windowStart = _windowStartFor(picked);
      _selectedGroup = null;
    });
    _loadAppointments();
  }

  void _selectDate(DateTime date) {
    setState(() {
      _selectedDate = _stripTime(date);
      _selectedGroup = null;
    });
  }

  Future<void> _openBooking() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => NewAppointmentScreen(userRole: widget.userRole),
      ),
    );
    if (mounted) _loadAppointments();
  }

  Future<void> _updateStatus(
    _ScheduleAppointment appointment,
    String status,
  ) async {
    await _appointmentRepository.updateAppointment(appointment.id, {
      'status': status,
    });
    await _loadAppointments();
  }

  Future<void> _cancelAppointment(_ScheduleAppointment appointment) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancel booking?'),
        content: Text(
          '${appointment.customerName} at ${appointment.timeRange} will be marked as cancelled.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFE53935),
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Cancel Booking'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _updateStatus(appointment, 'cancelled');
    if (mounted) setState(() => _selectedGroup = null);
  }

  Future<void> _cancelAppointmentGroup(_AppointmentGroup group) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancel group booking?'),
        content: Text(
          '${group.customerName} (${group.paxCount} pax) at ${group.timeRange} will be marked as cancelled.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFE53935),
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Cancel Booking'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    for (final appointment in group.appointments) {
      await _appointmentRepository.updateAppointment(appointment.id, {
        'status': 'cancelled',
      });
    }
    await _loadAppointments();
    if (mounted) setState(() => _selectedGroup = null);
  }

  Future<void> _openEdit(_ScheduleAppointment appointment) async {
    final saved = await Navigator.push<Object?>(
      context,
      MaterialPageRoute(
        builder: (_) => NewAppointmentScreen(
          userRole: widget.userRole,
          editPayload: _editPayloadForAppointments([appointment]),
        ),
      ),
    );
    if (saved != null && mounted) {
      await _loadAppointments();
    }
  }

  Future<void> _openEditGroup(
    _AppointmentGroup group, {
    String? activeAppointmentId,
  }) async {
    final result = await Navigator.push<Object?>(
      context,
      MaterialPageRoute(
        builder: (_) => NewAppointmentScreen(
          userRole: widget.userRole,
          editPayload: _editPayloadForAppointments(
            group.appointments,
            activeAppointmentId: activeAppointmentId,
          ),
        ),
      ),
    );
    if (result == null || !mounted) return;

    await _loadAppointments();
    if (result == 'confirmGroupPayment') {
      final updated = _appointmentGroups
          .where((item) => item.id == group.id)
          .toList();
      if (updated.isNotEmpty && mounted) {
        await _openGroupCheckout(updated.first);
      }
    }
  }

  AppointmentEditPayload _editPayloadForAppointments(
    List<_ScheduleAppointment> appointments, {
    String? activeAppointmentId,
  }) {
    final sorted = [...appointments]
      ..sort((a, b) => a.startMinutes.compareTo(b.startMinutes));
    final primary = sorted.first;
    final activeIndex = sorted.indexWhere((a) => a.id == activeAppointmentId);
    return AppointmentEditPayload(
      appointmentId: sorted.length == 1 ? primary.id : null,
      appointmentGroupId: primary.appointmentGroupId.isEmpty
          ? null
          : primary.appointmentGroupId,
      date: primary.date,
      customerId: primary.customerId,
      customerName: primary.customerName,
      customerPhone: primary.customerPhone,
      activePaxIndex: activeIndex < 0 ? 0 : activeIndex,
      allocations: sorted.map((appointment) {
        final serviceIds = <String>{
          ...appointment.serviceItems
              .map((item) => item['id']?.toString() ?? '')
              .where((id) => id.isNotEmpty),
          if (appointment.serviceId.isNotEmpty) appointment.serviceId,
        }.toList();
        return AppointmentEditAllocation(
          appointmentId: appointment.id,
          serviceIds: serviceIds,
          therapistId: appointment.therapistId,
          roomId: appointment.roomId,
          startTime: appointment.startTime,
          endTime: appointment.endTime,
        );
      }).toList(),
    );
  }

  Future<void> _openCheckout(_ScheduleAppointment appointment) async {
    final checkedOut = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _AppointmentCheckoutSheet(appointment: appointment),
    );
    if (checkedOut == true && mounted) {
      await _loadAppointments();
    }
  }

  Future<void> _openGroupCheckout(_AppointmentGroup group) async {
    final checkedOut = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _AppointmentGroupCheckoutSheet(group: group),
    );
    if (checkedOut == true && mounted) {
      await _loadAppointments();
    }
  }

  Future<void> _startService(_ScheduleAppointment appointment) async {
    await _appointmentRepository.startAppointment(
      appointment.id,
      startedAt: DateTime.now(),
    );
    if (!mounted) return;
    await _loadAppointments();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Customer arrived - service started')),
    );
  }

  Future<void> _startGroupService(_AppointmentGroup group) async {
    await _appointmentRepository.startAppointmentGroup(
      group.appointments.map((appointment) => appointment.id),
      startedAt: DateTime.now(),
    );
    if (!mounted) return;
    await _loadAppointments();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Customers arrived - services started')),
    );
  }

  void _showMobileSummary(_AppointmentGroup group) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            16,
            0,
            16,
            MediaQuery.of(context).viewInsets.bottom + 16,
          ),
          child: group.isGroup
              ? _AppointmentGroupSummaryPanel(
                  group: group,
                  compact: true,
                  onClose: () => Navigator.pop(context),
                  onEditGroup: () async {
                    Navigator.pop(context);
                    await _openEditGroup(group);
                  },
                  onEditPax: (appointment) async {
                    Navigator.pop(context);
                    await _openEditGroup(
                      group,
                      activeAppointmentId: appointment.id,
                    );
                  },
                  onComplete: group.canAdvance
                      ? () async {
                          Navigator.pop(context);
                          if (group.hasPayment) {
                            await _startGroupService(group);
                          } else {
                            await _openGroupCheckout(group);
                          }
                        }
                      : null,
                  onCancel: group.isCompleted
                      ? null
                      : () async {
                          Navigator.pop(context);
                          await _cancelAppointmentGroup(group);
                        },
                )
              : _AppointmentSummaryPanel(
                  appointment: group.primary,
                  compact: true,
                  onClose: () => Navigator.pop(context),
                  onEdit: () async {
                    Navigator.pop(context);
                    await _openEdit(group.primary);
                  },
                  onComplete: group.primary.canAdvance
                      ? () async {
                          Navigator.pop(context);
                          if (group.primary.hasPayment) {
                            await _startService(group.primary);
                          } else {
                            await _openCheckout(group.primary);
                          }
                        }
                      : null,
                  onCancel: group.isCompleted
                      ? null
                      : () async {
                          Navigator.pop(context);
                          await _cancelAppointment(group.primary);
                        },
                ),
        ),
      ),
    );
  }

  void _showMobileCluster(List<_AppointmentGroup> appointments) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView.separated(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
          itemCount: appointments.length,
          separatorBuilder: (context, index) => const SizedBox(height: 10),
          itemBuilder: (context, index) {
            final appointment = appointments[index];
            return _MobileAppointmentCard(
              appointment: appointment,
              onTap: () {
                Navigator.pop(context);
                setState(() => _selectedGroup = appointment);
                _showMobileSummary(appointment);
              },
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isTablet = MediaQuery.of(context).size.width >= 900;
    return Scaffold(
      backgroundColor: const Color(0xFFF6F8FA),
      floatingActionButton: null,
      body: SafeArea(child: isTablet ? _buildTablet() : _buildMobile()),
    );
  }

  Widget _buildMobile() {
    return Stack(
      children: [
        Column(
          children: [
            _MobileScheduleHeader(
              selectedDate: _selectedDate,
              onBack: () => Navigator.pop(context),
            ),
            _ScheduleCalendarStrip(
              days: _visibleDays,
              selectedDate: _selectedDate,
              monthLabel: DateFormat('MMMM yyyy').format(_selectedDate),
              appointmentsForDay: _appointmentsForDay,
              onSelect: _selectDate,
              onPrevious: () => _moveDays(-1),
              onNext: () => _moveDays(1),
              onOpenCalendar: _openCalendarPicker,
              compact: true,
            ),
            Expanded(child: _buildMobileBody()),
          ],
        ),
        Positioned(
          left: 16,
          right: 16,
          bottom: 14,
          child: _StickyNewAppointmentButton(onPressed: _openBooking),
        ),
      ],
    );
  }

  Widget _buildMobileBody() {
    if (_loading) return const _ScheduleLoading();
    if (_error != null) return _ScheduleError(onRetry: _loadAppointments);

    final appointments = _selectedDayGroups;
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 90),
      children: [
        _MobileDaySummary(
          count: appointments.length,
          pending: _pendingCount,
          inProgress: _inProgressCount,
          completed: _completedCount,
          sales: _selectedDaySales,
        ),
        const SizedBox(height: 16),
        if (appointments.isEmpty)
          const _ScheduleEmptyState()
        else ...[
          const Text(
            'Upcoming Appointments',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w900,
              color: _scheduleInk,
            ),
          ),
          const SizedBox(height: 10),
          _MobileTimeline(
            appointments: appointments,
            onTapAppointment: (appointment) {
              setState(() => _selectedGroup = appointment);
              _showMobileSummary(appointment);
            },
            onTapCluster: _showMobileCluster,
          ),
        ],
      ],
    );
  }

  Widget _buildTablet() {
    return Stack(
      children: [
        Positioned.fill(
          child: Column(
            children: [
              _TabletScheduleHeader(
                searchController: _searchController,
                onBack: () => Navigator.pop(context),
                onAdd: _openBooking,
              ),
              _ScheduleCalendarStrip(
                days: _visibleDays,
                selectedDate: _selectedDate,
                monthLabel: DateFormat('MMMM yyyy').format(_selectedDate),
                appointmentsForDay: _appointmentsForDay,
                onSelect: _selectDate,
                onPrevious: () => _moveDays(-1),
                onNext: () => _moveDays(1),
                onOpenCalendar: _openCalendarPicker,
                compact: false,
              ),

              Expanded(child: _buildTabletBody()),
            ],
          ),
        ),
        AnimatedPositioned(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          top: 198,
          right: _selectedGroup == null ? -390 : 18,
          bottom: 18,
          width: 360,
          child: IgnorePointer(
            ignoring: _selectedGroup == null,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 140),
              opacity: _selectedGroup == null ? 0 : 1,
              child: _selectedGroup == null
                  ? const SizedBox.shrink()
                  : _selectedGroup!.isGroup
                  ? _AppointmentGroupSummaryPanel(
                      group: _selectedGroup!,
                      onClose: () => setState(() => _selectedGroup = null),
                      onEditGroup: () => _openEditGroup(_selectedGroup!),
                      onEditPax: (appointment) => _openEditGroup(
                        _selectedGroup!,
                        activeAppointmentId: appointment.id,
                      ),
                      onComplete: _selectedGroup!.canAdvance
                          ? () => _selectedGroup!.hasPayment
                                ? _startGroupService(_selectedGroup!)
                                : _openGroupCheckout(_selectedGroup!)
                          : null,
                      onCancel: _selectedGroup!.isCompleted
                          ? null
                          : () => _cancelAppointmentGroup(_selectedGroup!),
                    )
                  : _AppointmentSummaryPanel(
                      appointment: _selectedGroup!.primary,
                      onClose: () => setState(() => _selectedGroup = null),
                      onEdit: () => _openEdit(_selectedGroup!.primary),
                      onComplete: _selectedGroup!.primary.canAdvance
                          ? () => _selectedGroup!.primary.hasPayment
                                ? _startService(_selectedGroup!.primary)
                                : _openCheckout(_selectedGroup!.primary)
                          : null,
                      onCancel: _selectedGroup!.isCompleted
                          ? null
                          : () => _cancelAppointment(_selectedGroup!.primary),
                    ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTabletBody() {
    if (_loading) return const _ScheduleLoading();
    if (_error != null) return _ScheduleError(onRetry: _loadAppointments);

    final appointments = _selectedDayGroups;
    // The whole tablet body scrolls as one page, so the full day's schedule
    // and every therapist are reachable together instead of two separate
    // inner scroll areas.
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _TabletDaySummary(
            count: appointments.length,
            pending: _pendingCount,
            inProgress: _inProgressCount,
            completed: _completedCount,
            sales: _selectedDaySales,
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: appointments.isEmpty
                    ? const _ScheduleEmptyState()
                    : _TabletScheduleSection(
                        selectedDate: _selectedDate,
                        showTimeline: _showTabletTimeline,
                        onViewChanged: (showTimeline) =>
                            setState(() => _showTabletTimeline = showTimeline),
                        list: _TabletAppointmentList(
                          appointments: appointments,
                          selectedId: _selectedGroup?.id,
                          onSelect: (appointment) =>
                              setState(() => _selectedGroup = appointment),
                          onEdit: (appointment) => appointment.isGroup
                              ? _openEditGroup(appointment)
                              : _openEdit(appointment.primary),
                        ),
                        timeline: _TabletTimeline(
                          appointments: appointments,
                          openHour: _openHour,
                          closeHour: _closeHour,
                          selectedDate: _selectedDate,
                          selectedId: _selectedGroup?.id,
                          onSelect: (appointment) =>
                              setState(() => _selectedGroup = appointment),
                        ),
                      ),
              ),
              const SizedBox(width: 16),
              SizedBox(
                width: 330,
                child: _AppointmentTherapistPanel(
                  therapists: _therapists,
                  appointments: appointments,
                  selectedDate: _selectedDate,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// Shared brand palette for the schedule header/calendar chrome.
const _scheduleGreen = Color(0xFF0F6B3E);
const _scheduleAccent = Color(0xFF2F7D59);
const _scheduleInk = Color(0xFF0F172A);
const _scheduleMuted = Color(0xFF6B7280);
const _scheduleBorder = Color(0xFFE5E7EB);

class _MobileScheduleHeader extends StatelessWidget {
  final DateTime selectedDate;
  final VoidCallback onBack;

  const _MobileScheduleHeader({
    required this.selectedDate,
    required this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
      color: Colors.white,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: IconButton(
              onPressed: onBack,
              icon: const Icon(Icons.arrow_back_rounded, size: 26),
              color: _scheduleInk,
              visualDensity: VisualDensity.compact,
              tooltip: 'Back',
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Appointments',
                  style: TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w900,
                    color: _scheduleInk,
                    height: 1.05,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  DateFormat('EEEE, d MMMM yyyy').format(selectedDate),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF64748B),
                    height: 1.1,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: IconButton(
              onPressed: () {},
              icon: const Icon(Icons.notifications_none_rounded, size: 25),
              color: _scheduleInk,
              visualDensity: VisualDensity.compact,
              tooltip: 'Notifications',
            ),
          ),
        ],
      ),
    );
  }
}

class _StickyNewAppointmentButton extends StatelessWidget {
  final VoidCallback onPressed;

  const _StickyNewAppointmentButton({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        boxShadow: const [
          BoxShadow(
            color: Color(0x260F6B3E),
            blurRadius: 20,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: FilledButton.icon(
        onPressed: onPressed,
        icon: const Icon(Icons.add_rounded, size: 24),
        label: const Text(
          'New Appointment',
          style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w900),
        ),
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(50),
          backgroundColor: _scheduleGreen,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          elevation: 0,
        ),
      ),
    );
  }
}

class _TodayCalendarButton extends StatelessWidget {
  final bool compact;
  final VoidCallback onPressed;

  const _TodayCalendarButton({
    required this.compact,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final height = compact ? 38.0 : 38.0;
    return SizedBox(
      height: height,
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          padding: EdgeInsets.symmetric(horizontal: compact ? 12 : 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(compact ? 10 : 10),
          ),
          side: const BorderSide(color: Color(0xFFE5E7EB)),
          backgroundColor: Colors.white,
          foregroundColor: _scheduleInk,
        ),
        child: const Text(
          'Today',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}

class _TabletScheduleHeader extends StatelessWidget {
  final TextEditingController searchController;
  final VoidCallback onBack;
  final VoidCallback onAdd;

  const _TabletScheduleHeader({
    required this.searchController,
    required this.onBack,
    required this.onAdd,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 22, 12),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: _scheduleBorder)),
      ),
      child: Row(
        children: [
          _HeaderIconButton(icon: Icons.arrow_back_rounded, onPressed: onBack),
          const SizedBox(width: 14),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Appointments',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                    color: _scheduleInk,
                    height: 1.05,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  'Manage bookings and daily schedule',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: _scheduleMuted,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          SizedBox(
            width: 300,
            child: _HeaderSearchField(controller: searchController),
          ),
          const SizedBox(width: 12),
          FilledButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add_rounded, size: 19),
            label: const Text(
              'New Appointment',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
            ),
            style: FilledButton.styleFrom(
              backgroundColor: _scheduleGreen,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              elevation: 0,
            ),
          ),
        ],
      ),
    );
  }
}

// Standardised square icon button (back / secondary actions) with a subtle
// outline, matching the chrome used across the app's screens.
class _HeaderIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onPressed;

  const _HeaderIconButton({required this.icon, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 42,
      height: 42,
      child: Material(
        color: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: _scheduleBorder),
        ),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(12),
          child: Icon(icon, size: 20, color: _scheduleInk),
        ),
      ),
    );
  }
}

class _HeaderSearchField extends StatelessWidget {
  final TextEditingController controller;

  const _HeaderSearchField({required this.controller});

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      decoration: InputDecoration(
        isDense: true,
        hintText: 'Search customers, services, therapists...',
        hintStyle: const TextStyle(
          fontSize: 13.5,
          color: Color(0xFF9CA3AF),
          fontWeight: FontWeight.w500,
        ),
        prefixIcon: const Icon(
          Icons.search_rounded,
          size: 20,
          color: _scheduleMuted,
        ),
        filled: true,
        fillColor: const Color(0xFFF3F4F6),
        contentPadding: const EdgeInsets.symmetric(vertical: 13),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: _scheduleAccent, width: 1.4),
        ),
      ),
    );
  }
}

// Month/date jump button, shown inside the calendar strip.
class _MonthPickerButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final bool compact;

  const _MonthPickerButton({
    required this.label,
    required this.onTap,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 10 : 12,
            vertical: compact ? 8 : 9,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: _scheduleBorder),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.calendar_today_rounded,
                size: 16,
                color: _scheduleAccent,
              ),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  fontSize: compact ? 13 : 14,
                  fontWeight: FontWeight.w800,
                  color: _scheduleInk,
                ),
              ),
              const SizedBox(width: 4),
              const Icon(
                Icons.keyboard_arrow_down_rounded,
                size: 18,
                color: _scheduleMuted,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MonthCalendarDialog extends StatefulWidget {
  final DateTime initialDate;

  const _MonthCalendarDialog({required this.initialDate});

  @override
  State<_MonthCalendarDialog> createState() => _MonthCalendarDialogState();
}

class _MonthCalendarDialogState extends State<_MonthCalendarDialog> {
  late DateTime _visibleMonth;

  @override
  void initState() {
    super.initState();
    _visibleMonth = DateTime(widget.initialDate.year, widget.initialDate.month);
  }

  void _moveMonth(int offset) {
    setState(() {
      _visibleMonth = DateTime(
        _visibleMonth.year,
        _visibleMonth.month + offset,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final firstDay = DateTime(_visibleMonth.year, _visibleMonth.month, 1);
    final gridStart = firstDay.subtract(Duration(days: firstDay.weekday % 7));
    final days = List.generate(
      42,
      (index) => gridStart.add(Duration(days: index)),
    );
    final selected = _stripTime(widget.initialDate);
    final today = _stripTime(DateTime.now());

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 340),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      DateFormat('MMMM yyyy').format(_visibleMonth),
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF111827),
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => _moveMonth(-1),
                    icon: const Icon(Icons.chevron_left),
                    visualDensity: VisualDensity.compact,
                  ),
                  IconButton(
                    onPressed: () => _moveMonth(1),
                    icon: const Icon(Icons.chevron_right),
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: const [
                  _WeekdayLabel('SUN'),
                  _WeekdayLabel('MON'),
                  _WeekdayLabel('TUE'),
                  _WeekdayLabel('WED'),
                  _WeekdayLabel('THU'),
                  _WeekdayLabel('FRI'),
                  _WeekdayLabel('SAT'),
                ],
              ),
              const SizedBox(height: 8),
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 7,
                  mainAxisSpacing: 7,
                  crossAxisSpacing: 7,
                ),
                itemCount: days.length,
                itemBuilder: (context, index) {
                  final day = days[index];
                  final cleanDay = _stripTime(day);
                  final isSelected = cleanDay == selected;
                  final isToday = cleanDay == today;
                  final inMonth = day.month == _visibleMonth.month;

                  return InkWell(
                    onTap: () => Navigator.pop(context, cleanDay),
                    borderRadius: BorderRadius.circular(18),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 120),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isSelected
                            ? const Color(0xFF2F7D59)
                            : Colors.transparent,
                        border: isToday && !isSelected
                            ? Border.all(color: const Color(0xFF2F7D59))
                            : null,
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        '${day.day}',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: isSelected || isToday
                              ? FontWeight.w900
                              : FontWeight.w700,
                          color: isSelected
                              ? Colors.white
                              : inMonth
                              ? const Color(0xFF111827)
                              : const Color(0xFFCBD5E1),
                        ),
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: () => Navigator.pop(context, today),
                    icon: const Icon(Icons.today_outlined, size: 17),
                    label: const Text('Today'),
                    style: TextButton.styleFrom(
                      foregroundColor: const Color(0xFF2F7D59),
                      textStyle: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WeekdayLabel extends StatelessWidget {
  final String label;

  const _WeekdayLabel(this.label);

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Text(
        label,
        textAlign: TextAlign.center,
        style: const TextStyle(
          fontSize: 10,
          color: Color(0xFF6B7280),
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

class _ScheduleCalendarStrip extends StatelessWidget {
  final List<DateTime> days;
  final DateTime selectedDate;
  final String monthLabel;
  final List<_ScheduleAppointment> Function(DateTime date) appointmentsForDay;
  final ValueChanged<DateTime> onSelect;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onOpenCalendar;
  final bool compact;

  const _ScheduleCalendarStrip({
    required this.days,
    required this.selectedDate,
    required this.monthLabel,
    required this.appointmentsForDay,
    required this.onSelect,
    required this.onPrevious,
    required this.onNext,
    required this.onOpenCalendar,
    required this.compact,
  });

  @override
  Widget build(BuildContext context) {
    final today = _stripTime(DateTime.now());
    if (compact) {
      return Container(
        color: Colors.white,
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                _MonthPickerButton(
                  label: monthLabel,
                  onTap: onOpenCalendar,
                  compact: true,
                ),
                const Spacer(),
                _CalendarNavButton(
                  icon: Icons.chevron_left,
                  compact: true,
                  onPressed: onPrevious,
                ),
                const SizedBox(width: 10),
                _TodayCalendarButton(
                  compact: true,
                  onPressed: () => onSelect(today),
                ),
                const SizedBox(width: 10),
                _CalendarNavButton(
                  icon: Icons.chevron_right,
                  compact: true,
                  onPressed: onNext,
                ),
              ],
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 66,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: days.length,
                separatorBuilder: (_, _) => const SizedBox(width: 7),
                itemBuilder: (context, index) {
                  final day = days[index];
                  return SizedBox(
                    width: 50,
                    child: _DayTile(
                      day: day,
                      selected: _stripTime(day) == _stripTime(selectedDate),
                      count: appointmentsForDay(day).length,
                      compact: true,
                      onTap: () => onSelect(day),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      );
    }
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(24, 10, 24, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        DateFormat('EEEE, d MMMM yyyy').format(selectedDate),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 21,
                          fontWeight: FontWeight.w900,
                          color: _scheduleInk,
                          height: 1,
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    _MonthPickerButton(label: monthLabel, onTap: onOpenCalendar),
                  ],
                ),
              ),
              const SizedBox(width: 14),
              Align(
                alignment: Alignment.centerRight,
                child: _CalendarNavCluster(
                  compact: false,
                  onPrevious: onPrevious,
                  onToday: () => onSelect(today),
                  onNext: onNext,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 72,
            child: Row(
              children: days.map((day) {
                final selected = _stripTime(day) == _stripTime(selectedDate);
                final count = appointmentsForDay(day).length;
                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 5),
                    child: _DayTile(
                      day: day,
                      selected: selected,
                      count: count,
                      compact: false,
                      onTap: () => onSelect(day),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }
}

class _CalendarNavCluster extends StatelessWidget {
  final bool compact;
  final VoidCallback onPrevious;
  final VoidCallback onToday;
  final VoidCallback onNext;

  const _CalendarNavCluster({
    required this.compact,
    required this.onPrevious,
    required this.onToday,
    required this.onNext,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: compact ? 58 : 44,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _CalendarNavButton(
            icon: Icons.chevron_left,
            compact: compact,
            onPressed: onPrevious,
          ),
          SizedBox(width: compact ? 10 : 10),
          _TodayCalendarButton(compact: compact, onPressed: onToday),
          SizedBox(width: compact ? 10 : 10),
          _CalendarNavButton(
            icon: Icons.chevron_right,
            compact: compact,
            onPressed: onNext,
          ),
        ],
      ),
    );
  }
}

class _CalendarNavButton extends StatelessWidget {
  final IconData icon;
  final bool compact;
  final VoidCallback onPressed;

  const _CalendarNavButton({
    required this.icon,
    required this.compact,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final size = compact ? 36.0 : 38.0;
    return SizedBox(
      width: size,
      height: size,
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          padding: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(compact ? 12 : 12),
          ),
          side: const BorderSide(color: Color(0xFFE5E7EB)),
          backgroundColor: Colors.white,
        ),
        child: Icon(
          icon,
          size: compact ? 17 : 20,
          color: const Color(0xFF111827),
        ),
      ),
    );
  }
}

class _DayTile extends StatelessWidget {
  final DateTime day;
  final bool selected;
  final int count;
  final bool compact;
  final VoidCallback onTap;

  const _DayTile({
    required this.day,
    required this.selected,
    required this.count,
    required this.compact,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final countLabel = compact
        ? ''
        : '$count booking${count == 1 ? '' : 's'}';
    final selectedColor = compact
        ? const Color(0xFFE2F3EB)
        : const Color(0xFF0F7A43);
    final selectedText = compact ? const Color(0xFF0F6B3E) : Colors.white;
    final selectedSubtext = compact
        ? const Color(0xFF0F6B3E)
        : Colors.white;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        height: compact ? 62 : 68,
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 3 : 8,
          vertical: compact ? 5 : 7,
        ),
        decoration: BoxDecoration(
          color: selected ? selectedColor : Colors.white,
          borderRadius: BorderRadius.circular(compact ? 18 : 10),
          border: compact && !selected
              ? null
              : Border.all(
                  color: selected ? selectedColor : const Color(0xFFE5E7EB),
                ),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: compact
                        ? const Color(0x180F6B3E)
                        : const Color(0x220F7A43),
                    blurRadius: compact ? 12 : 14,
                    offset: const Offset(0, 5),
                  ),
                ]
              : null,
        ),
        // FittedBox keeps the day / date / count stack from overflowing the
        // fixed tile height, even when the OS text scale is bumped up.
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                compact
                    ? DateFormat('EEE').format(day)
                    : DateFormat('EEE').format(day).toUpperCase(),
                style: TextStyle(
                  fontSize: compact ? 11 : 10,
                  height: 1.1,
                  fontWeight: FontWeight.w800,
                  color: selected
                      ? selectedText
                      : compact
                      ? const Color(0xFF475569)
                      : const Color(0xFF111827),
                ),
              ),
              SizedBox(height: compact ? 3 : 3),
              Text(
                DateFormat('d').format(day),
                style: TextStyle(
                  fontSize: compact ? 21 : 20,
                  height: 1.05,
                  fontWeight: FontWeight.w900,
                  color: selected ? selectedText : const Color(0xFF111827),
                ),
              ),
              if (!compact) ...[
                const SizedBox(height: 3),
                Text(
                  countLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10,
                    height: 1.1,
                    fontWeight: FontWeight.w700,
                    color: selected
                        ? selectedSubtext
                        : const Color(0xFF64748B),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _MobileDaySummary extends StatelessWidget {
  final int count;
  final int pending;
  final int inProgress;
  final int completed;
  final double sales;

  const _MobileDaySummary({
    required this.count,
    required this.pending,
    required this.inProgress,
    required this.completed,
    required this.sales,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE5E7EB)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0D000000),
            blurRadius: 20,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _MobileStatCell(
                  icon: Icons.calendar_today_outlined,
                  label: 'Total',
                  value: '$count',
                  color: const Color(0xFF6D4AFF),
                ),
              ),
              Expanded(
                child: _MobileStatCell(
                  icon: Icons.schedule_outlined,
                  label: 'In Progress',
                  value: '$inProgress',
                  color: const Color(0xFFF97316),
                ),
              ),
              Expanded(
                child: _MobileStatCell(
                  icon: Icons.check_circle_outline,
                  label: 'Completed',
                  value: '$completed',
                  color: const Color(0xFF059669),
                ),
              ),
              Expanded(
                child: _MobileStatCell(
                  icon: Icons.hourglass_empty_rounded,
                  label: 'Awaiting',
                  value: '$pending',
                  color: const Color(0xFF6D4AFF),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: const Color(0xFFF0FDF4),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.payments_outlined,
                  size: 16,
                  color: Color(0xFF0F766E),
                ),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    "Today's Sales",
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF0F766E),
                    ),
                  ),
                ),
                Text(
                  'RM ${sales.toStringAsFixed(0)}',
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w900,
                    color: _scheduleInk,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MobileStatCell extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;

  const _MobileStatCell({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, color: color, size: 18),
        ),
        const SizedBox(height: 7),
        Text(
          value,
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w900,
            color: _scheduleInk,
            height: 1,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w800,
            color: color,
          ),
        ),
      ],
    );
  }
}

class _TabletDaySummary extends StatelessWidget {
  final int count;
  final int pending;
  final int inProgress;
  final int completed;
  final double sales;

  const _TabletDaySummary({
    required this.count,
    required this.pending,
    required this.inProgress,
    required this.completed,
    required this.sales,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _TabletStatCard(
            icon: Icons.calendar_today_outlined,
            label: "Total Appointments",
            value: count,
            color: const Color(0xFF2563EB),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _TabletStatCard(
            icon: Icons.play_circle_outline,
            label: 'In Progress',
            value: inProgress,
            color: const Color(0xFFF97316),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _TabletStatCard(
            icon: Icons.check_circle_outline,
            label: 'Completed',
            value: completed,
            color: const Color(0xFF059669),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _TabletStatCard(
            icon: Icons.pending_actions_outlined,
            label: 'Awaiting',
            value: pending,
            color: const Color(0xFF7C3AED),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _TabletMoneyStatCard(
            icon: Icons.payments_outlined,
            label: 'Sales',
            value: 'RM ${sales.toStringAsFixed(0)}',
            color: const Color(0xFF0F766E),
          ),
        ),
      ],
    );
  }
}

class _TabletStatCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final int value;
  final Color color;

  const _TabletStatCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 78),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x06000000),
            blurRadius: 16,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: color, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF334155),
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  '$value',
                  style: const TextStyle(
                    fontSize: 21,
                    fontWeight: FontWeight.w900,
                    color: Color(0xFF0F172A),
                    height: 1,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TabletMoneyStatCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;

  const _TabletMoneyStatCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 78),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x06000000),
            blurRadius: 16,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: color, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF334155),
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w900,
                    color: Color(0xFF0F172A),
                    height: 1,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TabletScheduleSection extends StatelessWidget {
  final DateTime selectedDate;
  final bool showTimeline;
  final ValueChanged<bool> onViewChanged;
  final Widget list;
  final Widget timeline;

  const _TabletScheduleSection({
    required this.selectedDate,
    required this.showTimeline,
    required this.onViewChanged,
    required this.list,
    required this.timeline,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFDDE5EE)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x07000000),
            blurRadius: 18,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Schedule for ${DateFormat('EEEE, d MMMM yyyy').format(selectedDate)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                    color: _scheduleInk,
                  ),
                ),
              ),
              const SizedBox(width: 14),
              const _ScheduleStatusFilterButton(),
              const SizedBox(width: 10),
              _ScheduleViewToggle(
                showTimeline: showTimeline,
                onChanged: onViewChanged,
              ),
            ],
          ),
          const SizedBox(height: 16),
          showTimeline ? timeline : list,
        ],
      ),
    );
  }
}

class _ScheduleStatusFilterButton extends StatelessWidget {
  const _ScheduleStatusFilterButton();

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: () {},
      icon: const Icon(Icons.filter_alt_outlined, size: 17),
      label: const Text('All Status'),
      style: OutlinedButton.styleFrom(
        foregroundColor: _scheduleInk,
        backgroundColor: Colors.white,
        side: const BorderSide(color: Color(0xFFE5E7EB)),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        textStyle: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

class _ScheduleViewToggle extends StatelessWidget {
  final bool showTimeline;
  final ValueChanged<bool> onChanged;

  const _ScheduleViewToggle({
    required this.showTimeline,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ScheduleViewButton(
            icon: Icons.list_rounded,
            label: 'List',
            selected: !showTimeline,
            onTap: () => onChanged(false),
          ),
          _ScheduleViewButton(
            icon: Icons.schedule_outlined,
            label: 'Timeline',
            selected: showTimeline,
            onTap: () => onChanged(true),
          ),
        ],
      ),
    );
  }
}

class _ScheduleViewButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _ScheduleViewButton({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? Colors.white : Colors.transparent,
      borderRadius: BorderRadius.circular(7),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(7),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(7),
            border: selected
                ? Border.all(color: const Color(0xFFCFE9DD))
                : Border.all(color: Colors.transparent),
          ),
          child: Row(
            children: [
              Icon(
                icon,
                size: 17,
                color: selected ? _scheduleGreen : const Color(0xFF475569),
              ),
              const SizedBox(width: 7),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w900,
                  color: selected ? _scheduleGreen : _scheduleInk,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TabletAppointmentList extends StatelessWidget {
  final List<_AppointmentGroup> appointments;
  final String? selectedId;
  final ValueChanged<_AppointmentGroup> onSelect;
  final ValueChanged<_AppointmentGroup> onEdit;

  const _TabletAppointmentList({
    required this.appointments,
    required this.selectedId,
    required this.onSelect,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final sorted = [...appointments]
      ..sort((a, b) => a.startMinutes.compareTo(b.startMinutes));

    // Show every booking for the day, inserting a time band whenever the
    // start time changes so bookings at different times read as groups.
    final rows = <Widget>[const _TabletAppointmentListHeader()];
    String? lastTimeLabel;
    for (var i = 0; i < sorted.length; i++) {
      final appointment = sorted[i];
      final timeLabel = _clockLabel(_minutesToTime(appointment.startMinutes));
      if (timeLabel != lastTimeLabel) {
        rows.add(_TabletTimeBand(label: timeLabel));
        lastTimeLabel = timeLabel;
      }
      rows.add(
        _TabletAppointmentListRow(
          appointment: appointment,
          selected: selectedId == appointment.id,
          isLast: i == sorted.length - 1,
          onTap: () => onSelect(appointment),
          onEdit: () => onEdit(appointment),
        ),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: const Color(0xFFE5E7EB)),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(children: rows),
      ),
    );
  }
}

/// Slim time separator between bookings that start at different times.
class _TabletTimeBand extends StatelessWidget {
  final String label;

  const _TabletTimeBand({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
      decoration: const BoxDecoration(
        color: Color(0xFFF6FAF7),
        border: Border(
          top: BorderSide(color: Color(0xFFE5E7EB)),
          bottom: BorderSide(color: Color(0xFFE5E7EB)),
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.schedule_rounded, size: 14, color: _scheduleGreen),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w900,
              color: _scheduleGreen,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }
}

// Fixed column widths shared by the header and every row so the labels line
// up with their cells. Customer + Booking details flex to fill the rest.
const double _apptColTime = 120;
const double _apptColStatus = 132;
const double _apptColAmount = 80;
const double _apptColActions = 52;

class _TabletAppointmentListHeader extends StatelessWidget {
  const _TabletAppointmentListHeader();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 42,
      // Left inset matches the 4px status border + 16px row padding below.
      padding: const EdgeInsets.only(left: 20, right: 16),
      decoration: const BoxDecoration(
        color: Color(0xFFFBFCFE),
        border: Border(bottom: BorderSide(color: Color(0xFFE5E7EB))),
      ),
      child: const Row(
        children: [
          SizedBox(width: _apptColTime, child: _TabletColumnLabel('Time')),
          Expanded(flex: 5, child: _TabletColumnLabel('Customer')),
          Expanded(flex: 7, child: _TabletColumnLabel('Booking details')),
          SizedBox(
            width: _apptColStatus,
            child: _TabletColumnLabel('Payment status'),
          ),
          SizedBox(
            width: _apptColAmount,
            child: _TabletColumnLabel('Amount', align: TextAlign.right),
          ),
          SizedBox(
            width: _apptColActions,
            child: _TabletColumnLabel('Actions', align: TextAlign.center),
          ),
        ],
      ),
    );
  }
}

class _TabletColumnLabel extends StatelessWidget {
  final String label;
  final TextAlign align;

  const _TabletColumnLabel(this.label, {this.align = TextAlign.left});

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: align,
      style: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w900,
        color: Color(0xFF475569),
      ),
    );
  }
}

class _TabletAppointmentListRow extends StatelessWidget {
  final _AppointmentGroup appointment;
  final bool selected;
  final bool isLast;
  final VoidCallback onTap;
  final VoidCallback onEdit;

  const _TabletAppointmentListRow({
    required this.appointment,
    required this.selected,
    required this.isLast,
    required this.onTap,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final colors = _statusColorsForGroup(appointment);
    final serviceLabel = _appointmentServiceLabel(appointment);
    final startClock = _clockLabel(
      _minutesToTime(appointment.primary.startMinutes),
    );
    final endClock = _clockLabel(
      _minutesToTime(appointment.primary.endMinutes),
    );
    final timeRange = _compactTimeRange(startClock, endClock);
    final durationLabel = '${appointment.primary.durationMinutes} min';
    final customerDetailParts = [
      if (appointment.customerGender.isNotEmpty) appointment.customerGender,
      if (appointment.customerPhone.trim().isNotEmpty &&
          appointment.customerPhone.trim() != '-')
        appointment.customerPhone,
    ];
    final customerDetail = customerDetailParts.isEmpty
        ? 'Customer details unavailable'
        : customerDetailParts.join(' · ');

    return Material(
      color: selected ? colors.bg : Colors.white,
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 88),
          decoration: BoxDecoration(
            border: Border(
              // Coloured status indicator, constant width so columns stay
              // aligned whether or not the row is selected.
              left: BorderSide(color: colors.accent, width: 4),
              bottom: BorderSide(
                color: isLast ? Colors.transparent : const Color(0xFFE5E7EB),
              ),
            ),
          ),
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Time
              SizedBox(
                width: _apptColTime,
                child: Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        timeRange,
                        maxLines: 2,
                        softWrap: true,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w900,
                          color: _scheduleInk,
                          height: 1.15,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        durationLabel,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF64748B),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // Customer
              Expanded(
                flex: 5,
                child: Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        appointment.customerName,
                        maxLines: 2,
                        softWrap: true,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w900,
                          color: _scheduleInk,
                          height: 1.2,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        customerDetail,
                        maxLines: 2,
                        softWrap: true,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF64748B),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // Booking details
              Expanded(
                flex: 7,
                child: Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        serviceLabel,
                        maxLines: 2,
                        softWrap: true,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w800,
                          color: _scheduleInk,
                          height: 1.2,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 14,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          _BookingMeta(
                            icon: Icons.person_outline,
                            text: appointment.therapistName,
                          ),
                          _BookingMeta(
                            icon: Icons.meeting_room_outlined,
                            text: appointment.roomName,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              // Status + payment
              SizedBox(
                width: _apptColStatus,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _ListStatusChip(
                      label: appointment.statusLabel,
                      colors: colors,
                    ),
                    const SizedBox(height: 5),
                    _PaymentPill(paymentStatus: appointment.paymentStatus),
                  ],
                ),
              ),
              // Amount
              SizedBox(
                width: _apptColAmount,
                child: Text(
                  appointment.priceLabel,
                  textAlign: TextAlign.right,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w900,
                    color: colors.accent,
                  ),
                ),
              ),
              // Actions
              SizedBox(
                width: _apptColActions,
                child: Center(
                  child: _ListIconButton(
                    icon: Icons.edit_outlined,
                    onTap: onEdit,
                    tooltip: 'Edit appointment',
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Compresses "10:00 AM" + "11:00 AM" into "10:00–11:00 AM" when the
/// meridiems match, otherwise keeps both.
String _compactTimeRange(String start, String end) {
  final s = start.split(' ');
  final e = end.split(' ');
  if (s.length == 2 && e.length == 2 && s[1] == e[1]) {
    return '${s[0]}–${e[0]} ${e[1]}';
  }
  return '$start – $end';
}

/// Small icon + label used on the booking-details second line. The label
/// wraps rather than clipping when the service or room name is long.
class _BookingMeta extends StatelessWidget {
  final IconData icon;
  final String text;

  const _BookingMeta({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(icon, size: 14, color: const Color(0xFF94A3B8)),
        ),
        const SizedBox(width: 5),
        Flexible(
          child: Text(
            text,
            softWrap: true,
            style: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: Color(0xFF475569),
            ),
          ),
        ),
      ],
    );
  }
}

class _ListStatusChip extends StatelessWidget {
  final String label;
  final _AppointmentStatusStyle colors;

  const _ListStatusChip({required this.label, required this.colors});

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 130),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: colors.accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w800,
          color: colors.accent,
        ),
      ),
    );
  }
}

/// Compact payment-status pill for dense list rows.
class _PaymentPill extends StatelessWidget {
  final String paymentStatus;

  const _PaymentPill({required this.paymentStatus});

  @override
  Widget build(BuildContext context) {
    final normalized = paymentStatus.toLowerCase();
    late final Color accent;
    late final String label;
    switch (normalized) {
      case 'paid':
        accent = const Color(0xFF059669);
        label = 'Paid';
        break;
      case 'refunded':
        accent = const Color(0xFF6B7280);
        label = 'Refunded';
        break;
      case 'voided':
        accent = const Color(0xFF6B7280);
        label = 'Voided';
        break;
      default:
        accent = const Color(0xFFD97706);
        label = 'Unpaid';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              color: accent,
            ),
          ),
        ],
      ),
    );
  }
}

class _ListIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final String tooltip;

  const _ListIconButton({
    required this.icon,
    required this.onTap,
    required this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(9),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(9),
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: const Color(0xFFE5E7EB)),
            ),
            child: Icon(icon, size: 20, color: _scheduleInk),
          ),
        ),
      ),
    );
  }
}

class _AppointmentTherapistPanel extends StatelessWidget {
  final List<_AppointmentTherapist> therapists;
  final List<_AppointmentGroup> appointments;
  final DateTime selectedDate;

  const _AppointmentTherapistPanel({
    required this.therapists,
    required this.appointments,
    required this.selectedDate,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFDDE5EE)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x07000000),
            blurRadius: 18,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Therapists',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                    color: Color(0xFF0F172A),
                  ),
                ),
              ),
              Text(
                '${therapists.length}',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w900,
                  color: Color(0xFF0F766E),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            'Availability for the selected day',
            style: TextStyle(
              fontSize: 12,
              color: Color(0xFF64748B),
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 14),
          if (therapists.isEmpty)
            const _TherapistPanelEmpty()
          else
            // Shrink-wrapped so every therapist shows and the whole tablet
            // page scrolls as one, rather than this panel scrolling on its own.
            for (final (index, item) in _sortedTherapistsForDay(
              therapists: therapists,
              appointments: appointments,
              selectedDate: selectedDate,
            ).indexed) ...[
              if (index > 0) const SizedBox(height: 10),
              _TherapistStatusTile(
                therapist: item.therapist,
                status: item.status,
              ),
            ],
        ],
      ),
    );
  }
}

class _TherapistPanelEmpty extends StatelessWidget {
  const _TherapistPanelEmpty();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Text(
        'No therapists found',
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: Color(0xFF64748B),
        ),
      ),
    );
  }
}

class _TherapistStatusTile extends StatelessWidget {
  final _AppointmentTherapist therapist;
  final _TherapistDayStatus status;

  const _TherapistStatusTile({
    required this.therapist,
    required this.status,
  });

  @override
  Widget build(BuildContext context) {
    final color = _avatarColor(therapist.name);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFBFCFE),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 20,
            backgroundColor: color.withValues(alpha: 0.12),
            child: Text(
              therapist.initials,
              style: TextStyle(
                fontWeight: FontWeight.w900,
                color: color,
              ),
            ),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  therapist.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w900,
                    color: Color(0xFF0F172A),
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  status.detail,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF64748B),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _TherapistStatusPill(status: status),
        ],
      ),
    );
  }
}

class _TherapistStatusPill extends StatelessWidget {
  final _TherapistDayStatus status;

  const _TherapistStatusPill({required this.status});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: status.color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: status.color,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 4),
          Text(
            status.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w900,
              color: status.color,
            ),
          ),
        ],
      ),
    );
  }
}

class _TherapistDayStatus {
  final String label;
  final String detail;
  final Color color;

  const _TherapistDayStatus({
    required this.label,
    required this.detail,
    required this.color,
  });
}

class _TherapistSortItem {
  final _AppointmentTherapist therapist;
  final _TherapistDayStatus status;

  const _TherapistSortItem({required this.therapist, required this.status});
}

List<_TherapistSortItem> _sortedTherapistsForDay({
  required List<_AppointmentTherapist> therapists,
  required List<_AppointmentGroup> appointments,
  required DateTime selectedDate,
}) {
  final items = therapists.map((therapist) {
    return _TherapistSortItem(
      therapist: therapist,
      status: _therapistDayStatus(
        therapist: therapist,
        appointments: appointments,
        selectedDate: selectedDate,
      ),
    );
  }).toList();
  items.sort((a, b) {
    final rank = _therapistStatusRank(a.status)
        .compareTo(_therapistStatusRank(b.status));
    if (rank != 0) return rank;
    return a.therapist.name.compareTo(b.therapist.name);
  });
  return items;
}

int _therapistStatusRank(_TherapistDayStatus status) {
  final label = status.label.toLowerCase();
  final detail = status.detail.toLowerCase();
  if (label == 'in session' || label == 'cleaning') return 0;
  if (label == 'available' && !detail.startsWith('next')) return 1;
  if (label == 'available' && detail.startsWith('next')) return 2;
  if (label == 'open' || detail.contains('no bookings')) return 3;
  return 4;
}

_TherapistDayStatus _therapistDayStatus({
  required _AppointmentTherapist therapist,
  required List<_AppointmentGroup> appointments,
  required DateTime selectedDate,
}) {
  if (!therapist.available) {
    return const _TherapistDayStatus(
      label: 'Unavailable',
      detail: 'Not taking appointments',
      color: Color(0xFF64748B),
    );
  }

  final assigned = appointments
      .where(
        (group) => group.appointments.any(
          (appointment) => appointment.therapistId == therapist.id,
        ),
      )
      .toList();
  final today = _stripTime(DateTime.now());
  final selectedToday = _stripTime(selectedDate) == today;
  if (!selectedToday) {
    return _TherapistDayStatus(
      label: assigned.isEmpty ? 'Open' : '${assigned.length} booked',
      detail: assigned.isEmpty ? 'No bookings' : 'Selected day schedule',
      color: assigned.isEmpty ? const Color(0xFF10B981) : const Color(0xFF2563EB),
    );
  }

  final now = DateTime.now();
  final nowMinutes = now.hour * 60 + now.minute;
  final active = assigned.where((group) {
    return nowMinutes >= group.startMinutes &&
        nowMinutes < group.cleanupEndMinutes;
  }).toList();
  if (active.isNotEmpty) {
    active.sort((a, b) => a.cleanupEndMinutes.compareTo(b.cleanupEndMinutes));
    final current = active.first;
    if (nowMinutes >= current.endMinutes) {
      return _TherapistDayStatus(
        label: 'Cleaning',
        detail:
            'Until ${_clockLabel(_minutesToTime(current.cleanupEndMinutes))}',
        color: const Color(0xFFF59E0B),
      );
    }
    return _TherapistDayStatus(
      label: 'In session',
      detail: 'Until ${_clockLabel(_minutesToTime(current.endMinutes))}',
      color: const Color(0xFFF97316),
    );
  }

  final upcoming = assigned
      .where((group) => group.startMinutes > nowMinutes)
      .toList()
    ..sort((a, b) => a.startMinutes.compareTo(b.startMinutes));
  if (upcoming.isNotEmpty) {
    return _TherapistDayStatus(
      label: 'Available',
      detail: 'Next ${_clockLabel(_minutesToTime(upcoming.first.startMinutes))}',
      color: const Color(0xFF10B981),
    );
  }
  return _TherapistDayStatus(
    label: 'Available',
    detail: assigned.isEmpty
        ? 'No bookings today'
        : '${assigned.length} ${assigned.length == 1 ? 'booking' : 'bookings'}',
    color: const Color(0xFF10B981),
  );
}

class _TimelinePlacement {
  final _AppointmentGroup appointment;
  final int lane;
  final int laneCount;

  const _TimelinePlacement({
    required this.appointment,
    required this.lane,
    required this.laneCount,
  });
}

// Resolved geometry for one timeline card, so heights can be capped against
// following cards that would otherwise be overlapped by the readable minimum.
class _TimelineCardRect {
  final _TimelinePlacement placement;
  final double left;
  final double width;
  final double top;
  final double rawHeight;
  double height;

  _TimelineCardRect({
    required this.placement,
    required this.left,
    required this.width,
    required this.top,
    required this.rawHeight,
  }) : height = rawHeight;
}

double _calculateTop(int startMinutes, int openHour, double hourHeight) {
  final minutesFromStart = startMinutes - openHour * 60;
  return minutesFromStart * (hourHeight / 60);
}

double _calculateHeight(int startMinutes, int endMinutes, double hourHeight) {
  final duration = (endMinutes - startMinutes).clamp(0, 24 * 60);
  return duration * (hourHeight / 60);
}

List<List<_AppointmentGroup>> _buildOverlapGroups(
  List<_AppointmentGroup> appointments,
) {
  final sorted = [...appointments]
    ..sort((a, b) => a.startMinutes.compareTo(b.startMinutes));
  final groups = <List<_AppointmentGroup>>[];
  var current = <_AppointmentGroup>[];
  var currentEnd = -1;

  for (final appointment in sorted) {
    if (current.isEmpty || appointment.startMinutes < currentEnd) {
      current.add(appointment);
      if (appointment.endMinutes > currentEnd) {
        currentEnd = appointment.endMinutes;
      }
    } else {
      groups.add(current);
      current = [appointment];
      currentEnd = appointment.endMinutes;
    }
  }

  if (current.isNotEmpty) groups.add(current);
  return groups;
}

List<_TimelinePlacement> _assignOverlapLanes(
  List<_AppointmentGroup> appointments,
) {
  final placements = <_TimelinePlacement>[];
  for (final group in _buildOverlapGroups(appointments)) {
    final lanesEnd = <int>[];
    final laneByAppointment = <String, int>{};

    for (final appointment in group) {
      var lane = lanesEnd.indexWhere((end) => appointment.startMinutes >= end);
      if (lane == -1) {
        lane = lanesEnd.length;
        lanesEnd.add(appointment.endMinutes);
      } else {
        lanesEnd[lane] = appointment.endMinutes;
      }
      laneByAppointment[appointment.id] = lane;
    }

    final laneCount = lanesEnd.length.clamp(1, 6);
    for (final appointment in group) {
      placements.add(
        _TimelinePlacement(
          appointment: appointment,
          lane: (laneByAppointment[appointment.id] ?? 0)
              .clamp(0, laneCount - 1)
              .toInt(),
          laneCount: laneCount,
        ),
      );
    }
  }
  return placements;
}

class _MobileTimeline extends StatelessWidget {
  final List<_AppointmentGroup> appointments;
  final ValueChanged<_AppointmentGroup> onTapAppointment;
  final ValueChanged<List<_AppointmentGroup>> onTapCluster;

  const _MobileTimeline({
    required this.appointments,
    required this.onTapAppointment,
    required this.onTapCluster,
  });

  @override
  Widget build(BuildContext context) {
    final groups = _buildOverlapGroups(appointments);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var groupIndex = 0; groupIndex < groups.length; groupIndex++) ...[
          _MobileAgendaTimeHeader(
            appointments: groups[groupIndex],
            onTap: groups[groupIndex].length > 1
                ? () => onTapCluster(groups[groupIndex])
                : null,
          ),
          const SizedBox(height: 8),
          for (var index = 0; index < groups[groupIndex].length; index++) ...[
            _MobileAppointmentCard(
              appointment: groups[groupIndex][index],
              onTap: () => onTapAppointment(groups[groupIndex][index]),
            ),
            if (index != groups[groupIndex].length - 1)
              const SizedBox(height: 8),
          ],
          if (groupIndex != groups.length - 1) const SizedBox(height: 18),
        ],
      ],
    );
  }
}

class _MobileAgendaTimeHeader extends StatelessWidget {
  final List<_AppointmentGroup> appointments;
  final VoidCallback? onTap;

  const _MobileAgendaTimeHeader({required this.appointments, this.onTap});

  @override
  Widget build(BuildContext context) {
    final start = appointments
        .map((appointment) => appointment.startMinutes)
        .reduce((a, b) => a < b ? a : b);
    final end = appointments
        .map((appointment) => appointment.endMinutes)
        .reduce((a, b) => a > b ? a : b);
    final concurrent = appointments.length > 1;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: concurrent
                    ? const Color(0xFFF3E8FF)
                    : const Color(0xFFE8F5F1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                concurrent ? Icons.layers_outlined : Icons.schedule_outlined,
                size: 18,
                color: concurrent
                    ? const Color(0xFF7C3AED)
                    : const Color(0xFF176B68),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    concurrent
                        ? '${appointments.length} concurrent bookings'
                        : _clockLabel(_minutesToTime(start)),
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF17202A),
                    ),
                  ),
                  if (concurrent)
                    Text(
                      '${_clockLabel(_minutesToTime(start))} - ${_clockLabel(_minutesToTime(end))}',
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF667085),
                      ),
                    ),
                ],
              ),
            ),
            if (concurrent)
              const Icon(
                Icons.open_in_new,
                size: 16,
                color: Color(0xFF667085),
              ),
          ],
        ),
      ),
    );
  }
}

class _TabletTimeline extends StatelessWidget {
  final List<_AppointmentGroup> appointments;
  final int openHour;
  final int closeHour;
  final DateTime selectedDate;
  final String? selectedId;
  final ValueChanged<_AppointmentGroup> onSelect;

  const _TabletTimeline({
    required this.appointments,
    required this.openHour,
    required this.closeHour,
    required this.selectedDate,
    required this.selectedId,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    const hourHeight = 78.0;
    const labelWidth = 58.0;
    const gutter = 16.0;
    final totalHeight = (closeHour - openHour) * hourHeight;
    final placements = _assignOverlapLanes(appointments);

    return SizedBox(
      height: totalHeight,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final canvasLeft = labelWidth + gutter;
          final canvasWidth = constraints.maxWidth - canvasLeft;
          const spacing = 10.0;

          // Resolve each card's geometry first.
          final rects = <_TimelineCardRect>[];
          for (final placement in placements) {
            final laneWidth =
                (canvasWidth - spacing * (placement.laneCount - 1)) /
                placement.laneCount;
            rects.add(
              _TimelineCardRect(
                placement: placement,
                left: canvasLeft + placement.lane * (laneWidth + spacing),
                width: laneWidth,
                top: _calculateTop(
                  placement.appointment.startMinutes,
                  openHour,
                  hourHeight,
                ),
                rawHeight: _calculateHeight(
                  placement.appointment.startMinutes,
                  placement.appointment.endMinutes,
                  hourHeight,
                ),
              ),
            );
          }

          // Short appointments get a readable minimum height, but a card must
          // never grow past the top of a following card that shares its
          // horizontal band, otherwise touching/back-to-back slots overlap.
          const laneGap = 4.0;
          for (final rect in rects) {
            var height = rect.rawHeight.clamp(42.0, 260.0).toDouble();
            double? nextTop;
            for (final other in rects) {
              if (identical(other, rect)) continue;
              if (other.top <= rect.top + 0.5) continue;
              final overlapsHorizontally =
                  other.left < rect.left + rect.width - 0.5 &&
                  other.left + other.width > rect.left + 0.5;
              if (!overlapsHorizontally) continue;
              if (nextTop == null || other.top < nextTop) nextTop = other.top;
            }
            if (nextTop != null) {
              final available = nextTop - rect.top - laneGap;
              if (available < height) {
                height = available.clamp(20.0, 260.0).toDouble();
              }
            }
            rect.height = height;
          }

          return Stack(
            clipBehavior: Clip.none,
            children: [
              _TimelineGrid(
                openHour: openHour,
                closeHour: closeHour,
                hourHeight: hourHeight,
                labelWidth: labelWidth,
                gutter: gutter,
                showNowLine:
                    _stripTime(selectedDate) == _stripTime(DateTime.now()),
              ),
              for (final rect in rects)
                Positioned(
                  top: rect.top,
                  left: rect.left,
                  width: rect.width,
                  height: rect.height,
                  child: _TabletAppointmentCardTile(
                    appointment: rect.placement.appointment,
                    selected: selectedId == rect.placement.appointment.id,
                    onTap: () => onSelect(rect.placement.appointment),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _TimelineGrid extends StatelessWidget {
  final int openHour;
  final int closeHour;
  final double hourHeight;
  final double labelWidth;
  final double gutter;
  final bool showNowLine;

  const _TimelineGrid({
    required this.openHour,
    required this.closeHour,
    required this.hourHeight,
    required this.labelWidth,
    required this.gutter,
    required this.showNowLine,
  });

  @override
  Widget build(BuildContext context) {
    final totalHeight = (closeHour - openHour) * hourHeight;
    final now = DateTime.now();
    final nowMinutes = now.hour * 60 + now.minute;
    final nowTop = _calculateTop(nowMinutes, openHour, hourHeight);
    final showNow =
        showNowLine &&
        nowMinutes >= openHour * 60 &&
        nowMinutes <= closeHour * 60;

    return Stack(
      children: [
        for (var hour = openHour; hour <= closeHour; hour++) ...[
          Positioned(
            top: (hour - openHour) * hourHeight,
            left: 0,
            width: labelWidth,
            child: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                _hourLabel(hour),
                textAlign: TextAlign.right,
                style: const TextStyle(
                  fontSize: 12,
                  color: Color(0xFF4B5563),
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
          Positioned(
            top: (hour - openHour) * hourHeight,
            left: labelWidth + gutter,
            right: 0,
            child: const Divider(height: 1, color: Color(0xFFE5E7EB)),
          ),
          if (hour < closeHour)
            Positioned(
              top: (hour - openHour) * hourHeight + hourHeight / 2,
              left: labelWidth + gutter,
              right: 0,
              child: const Divider(height: 1, color: Color(0xFFF1F5F9)),
            ),
        ],
        if (showNow)
          Positioned(
            top: nowTop.clamp(0.0, totalHeight),
            left: 0,
            right: 0,
            child: Row(
              children: [
                const SizedBox(
                  width: 38,
                  child: Text(
                    'NOW',
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      color: Color(0xFFE53935),
                      fontSize: 10,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  width: 9,
                  height: 9,
                  decoration: const BoxDecoration(
                    color: Color(0xFFE53935),
                    shape: BoxShape.circle,
                  ),
                ),
                Expanded(
                  child: Container(height: 2, color: const Color(0xFFE53935)),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

// ignore: unused_element
class _MobileTimelineBlock extends StatelessWidget {
  final _AppointmentGroup appointment;
  final VoidCallback onTap;

  const _MobileTimelineBlock({required this.appointment, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = _statusColorsForGroup(appointment);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: colors.bg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: colors.border),
          boxShadow: const [
            BoxShadow(
              color: Color(0x12000000),
              blurRadius: 10,
              offset: Offset(0, 3),
            ),
          ],
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxHeight < 62;
            return Row(
              children: [
                Container(
                  width: 4,
                  height: double.infinity,
                  decoration: BoxDecoration(
                    color: colors.accent,
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        appointment.customerName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w900,
                          color: Color(0xFF111827),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        compact
                            ? appointment.priceLabel
                            : appointment.servicePriceLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xFF4B5563),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: compact ? 112 : 138,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerRight,
                        child: Text(
                          appointment.timeRange,
                          maxLines: 1,
                          style: const TextStyle(
                            fontSize: 10,
                            color: Color(0xFF111827),
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      if (!compact) ...[
                        const SizedBox(height: 6),
                        _TimelineStatusBadge(
                          label: appointment.statusLabel,
                          colors: colors,
                          compact: true,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

// ignore: unused_element
class _MobileCollapsedBlock extends StatelessWidget {
  final List<_AppointmentGroup> appointments;
  final VoidCallback onTap;

  const _MobileCollapsedBlock({
    required this.appointments,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final first = appointments.first;
    final colors = _statusColorsFor(
      first.isPending,
      first.isCompleted,
      isInProgress: first.isInProgress,
      hasPayment: first.hasPayment,
      isLateArrival: first.isLateArrival,
      hasDelayWarning: first.hasDelayWarning,
    );
    final start = appointments
        .map((a) => a.startMinutes)
        .reduce((a, b) => a.compareTo(b) < 0 ? a : b);
    final end = appointments
        .map((a) => a.endMinutes)
        .reduce((a, b) => a.compareTo(b) > 0 ? a : b);
    final timeRange =
        '${_clockLabel(_minutesToTime(start))} - '
        '${_clockLabel(_minutesToTime(end))}';
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFFF3F8F2),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: colors.border),
          boxShadow: const [
            BoxShadow(
              color: Color(0x12000000),
              blurRadius: 10,
              offset: Offset(0, 3),
            ),
          ],
        ),
        child: Row(
          children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: colors.accent,
              child: Text(
                '${appointments.length}',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${appointments.length} overlapping bookings',
                    style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFF111827),
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    timeRange,
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFF4B5563),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.keyboard_arrow_up, color: Color(0xFF2F7D59)),
          ],
        ),
      ),
    );
  }
}

class _MobileAppointmentCard extends StatelessWidget {
  final _AppointmentGroup appointment;
  final VoidCallback onTap;

  const _MobileAppointmentCard({
    required this.appointment,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = _statusColorsForGroup(appointment);
    final startClock = _clockLabel(
      _minutesToTime(appointment.primary.startMinutes),
    );
    final endClock = _clockLabel(
      _minutesToTime(appointment.primary.endMinutes),
    );
    final timeLabel =
        '${_compactTimeRange(startClock, endClock)} · '
        '${appointment.primary.durationMinutes} min';
    return Material(
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: colors.border),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                width: 4,
                decoration: BoxDecoration(
                  color: colors.accent,
                  borderRadius: const BorderRadius.horizontal(
                    left: Radius.circular(12),
                  ),
                ),
              ),
              // Left: customer, service, time.
              Expanded(
                flex: 6,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 10, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        appointment.customerName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w900,
                          color: _scheduleInk,
                          height: 1.15,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _appointmentServiceLabel(appointment),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF334155),
                          height: 1.2,
                        ),
                      ),
                      const SizedBox(height: 8),
                      _MobileCardInfoRow(
                        icon: Icons.schedule_outlined,
                        label: timeLabel,
                      ),
                    ],
                  ),
                ),
              ),
              Container(width: 1, color: const Color(0xFFE5E7EB)),
              // Right: status, therapist, room, price.
              Expanded(
                flex: 5,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Align(
                        alignment: Alignment.centerRight,
                        child: _MobileAppointmentStatusTag(
                          label: appointment.statusLabel,
                          colors: colors,
                        ),
                      ),
                      const SizedBox(height: 10),
                      _MobileCardInfoRow(
                        icon: Icons.person_outline,
                        label: appointment.therapistName,
                      ),
                      const SizedBox(height: 6),
                      _MobileCardInfoRow(
                        icon: Icons.location_on_outlined,
                        label: appointment.roomName,
                      ),
                      const SizedBox(height: 10),
                      Align(
                        alignment: Alignment.centerRight,
                        child: Text(
                          appointment.priceLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w900,
                            color: colors.accent,
                            height: 1,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MobileCardInfoRow extends StatelessWidget {
  final IconData icon;
  final String label;

  const _MobileCardInfoRow({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 15, color: const Color(0xFF64748B)),
        const SizedBox(width: 7),
        Expanded(
          child: Text(
            label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: Color(0xFF475569),
              height: 1.25,
            ),
          ),
        ),
      ],
    );
  }
}

class _MobileAppointmentStatusTag extends StatelessWidget {
  final String label;
  final _AppointmentStatusStyle colors;

  const _MobileAppointmentStatusTag({
    required this.label,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 128),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: colors.accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 10.8,
          fontWeight: FontWeight.w900,
          color: colors.accent,
        ),
      ),
    );
  }
}

class _TabletAppointmentCardTile extends StatelessWidget {
  final _AppointmentGroup appointment;
  final bool selected;
  final VoidCallback onTap;

  const _TabletAppointmentCardTile({
    required this.appointment,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = _statusColorsForGroup(appointment);
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        decoration: BoxDecoration(
          color: colors.bg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? colors.accent : colors.border,
            width: selected ? 2 : 1,
          ),
          boxShadow: const [
            BoxShadow(
              color: Color(0x0D000000),
              blurRadius: 10,
              offset: Offset(0, 3),
            ),
          ],
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            final height = constraints.maxHeight;
            final serviceLabel = _appointmentServiceLabel(appointment);
            final serviceCount = _appointmentServiceCount(appointment);
            // Full-width single-lane cards span the whole row; narrower cards
            // are stacked beside concurrent bookings. The card background is
            // already tinted by status, so no status badge/dot is drawn.
            final fullRow = width >= 460;
            final timeText = width >= 240
                ? appointment.timeRange
                : appointment.durationLabel;

            final accent = Container(
              width: 4,
              decoration: BoxDecoration(
                color: colors.accent,
                borderRadius: BorderRadius.circular(99),
              ),
            );

            // THICK full-row card: plenty of height -> stack every detail,
            // wrapping the service names across up to three lines.
            if (fullRow && height >= 122) {
              return Padding(
                padding: const EdgeInsets.fromLTRB(12, 11, 14, 11),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    accent,
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Text(
                                  appointment.customerName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 15,
                                    color: Color(0xFF0F172A),
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Text(
                                appointment.priceLabel,
                                style: TextStyle(
                                  fontSize: 14,
                                  color: colors.accent,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 5),
                          _CardDetailLine(
                            icon: Icons.schedule_outlined,
                            text:
                                '${appointment.timeRange}  ·  ${appointment.durationLabel}',
                            color: colors.accent,
                          ),
                          const SizedBox(height: 4),
                          _CardDetailLine(
                            icon: Icons.spa_outlined,
                            text: serviceCount > 1
                                ? '$serviceLabel  ($serviceCount services)'
                                : serviceLabel,
                            maxLines: height >= 172 ? 3 : 2,
                            emphasize: true,
                          ),
                          const SizedBox(height: 4),
                          _CardDetailLine(
                            icon: Icons.person_outline,
                            text: appointment.therapistName,
                          ),
                          if (height >= 156) ...[
                            const SizedBox(height: 4),
                            _CardDetailLine(
                              icon: Icons.meeting_room_outlined,
                              text: appointment.roomName,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              );
            }

            // THIN full-row card: keep every detail on a single row of columns
            // (name | time | service | therapist | price). The time collapses
            // to its duration when the range is too long to fit its column.
            if (fullRow) {
              return Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    accent,
                    const SizedBox(width: 12),
                    Expanded(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(
                            flex: 18,
                            child: Text(
                              appointment.customerName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 13,
                                color: Color(0xFF0F172A),
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                          const _ThinCardDivider(),
                          Expanded(
                            flex: 15,
                            child: _AdaptiveTimeText(
                              full: appointment.timeRange,
                              fallback: appointment.durationLabel,
                              style: const TextStyle(
                                fontSize: 11.5,
                                color: Color(0xFF334155),
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          const _ThinCardDivider(),
                          Expanded(
                            flex: 24,
                            child: _ThinCardIconCell(
                              icon: Icons.spa_outlined,
                              text: serviceLabel,
                            ),
                          ),
                          const _ThinCardDivider(),
                          Expanded(
                            flex: 18,
                            child: _ThinCardIconCell(
                              icon: Icons.person_outline,
                              text: appointment.therapistName,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Text(
                            appointment.priceLabel,
                            maxLines: 1,
                            style: TextStyle(
                              fontSize: 12.5,
                              color: colors.accent,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            }

            // STACKED narrow card (concurrent bookings): stack name, service,
            // then time, with the price pinned center-right. When multiple
            // services would crowd the price, show the count instead of every
            // service name.
            final tiny = height < 48;
            final showService = height >= 66;
            final smallText = width < 170 || tiny;
            final narrowServiceText = serviceCount > 1
                ? '$serviceCount services'
                : serviceLabel;
            return Padding(
              padding: EdgeInsets.symmetric(
                horizontal: tiny ? 7 : 9,
                vertical: tiny ? 4 : 6,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  accent,
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          appointment.customerName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: smallText ? 12 : 13,
                            color: const Color(0xFF0F172A),
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        if (showService) ...[
                          const SizedBox(height: 3),
                          Text(
                            narrowServiceText,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 11,
                              color: Color(0xFF475569),
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                        const SizedBox(height: 3),
                        Text(
                          timeText,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: smallText ? 10.5 : 11.5,
                            color: const Color(0xFF374151),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Text(
                      appointment.priceLabel,
                      maxLines: 1,
                      style: TextStyle(
                        fontSize: smallText ? 11 : 12,
                        color: colors.accent,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

// Slim vertical separator between the columns of a thin full-row card.
class _ThinCardDivider extends StatelessWidget {
  const _ThinCardDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 22,
      margin: const EdgeInsets.symmetric(horizontal: 10),
      color: const Color(0xFFDDE5EE),
    );
  }
}

// A single icon + wrapping text line used inside the thick timeline card.
class _CardDetailLine extends StatelessWidget {
  final IconData icon;
  final String text;
  final int maxLines;
  final bool emphasize;
  final Color? color;

  const _CardDetailLine({
    required this.icon,
    required this.text,
    this.maxLines = 1,
    this.emphasize = false,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final textColor = color ?? const Color(0xFF475569);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(icon, size: 14, color: textColor),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            maxLines: maxLines,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: emphasize ? 12.5 : 12,
              color: emphasize ? const Color(0xFF334155) : textColor,
              fontWeight: emphasize ? FontWeight.w800 : FontWeight.w700,
              height: 1.2,
            ),
          ),
        ),
      ],
    );
  }
}

// A single-line icon + text column used inside the thin full-row card.
class _ThinCardIconCell extends StatelessWidget {
  final IconData icon;
  final String text;

  const _ThinCardIconCell({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: const Color(0xFF64748B)),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 12,
              color: Color(0xFF334155),
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}

// Shows the full time range when it fits its column, otherwise falls back to
// the shorter duration label (e.g. "21 mins") so the thin card stays on one row.
class _AdaptiveTimeText extends StatelessWidget {
  final String full;
  final String fallback;
  final TextStyle style;

  const _AdaptiveTimeText({
    required this.full,
    required this.fallback,
    required this.style,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(text: full, style: style),
          maxLines: 1,
          textDirection: Directionality.of(context),
        )..layout();
        final fits = painter.width <= constraints.maxWidth;
        return Text(
          fits ? full : fallback,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: style,
        );
      },
    );
  }
}

String _appointmentServiceLabel(_AppointmentGroup appointment) {
  final names = appointment.serviceItems
      .map((item) => item['name']?.toString().trim() ?? '')
      .where((name) => name.isNotEmpty)
      .toSet()
      .toList();
  if (names.isEmpty) return appointment.serviceName;
  return names.join(', ');
}

int _appointmentServiceCount(_AppointmentGroup appointment) {
  final names = appointment.serviceItems
      .map((item) => item['name']?.toString().trim() ?? '')
      .where((name) => name.isNotEmpty)
      .toSet();
  return names.isEmpty ? 1 : names.length;
}

class _AppointmentStatusStyle {
  final Color accent;
  final Color bg;
  final Color border;

  const _AppointmentStatusStyle({
    required this.accent,
    required this.bg,
    required this.border,
  });
}

class _AppointmentGroupSummaryPanel extends StatelessWidget {
  final _AppointmentGroup group;
  final bool compact;
  final VoidCallback onClose;
  final VoidCallback onEditGroup;
  final void Function(_ScheduleAppointment appointment) onEditPax;
  final VoidCallback? onComplete;
  final VoidCallback? onCancel;

  const _AppointmentGroupSummaryPanel({
    required this.group,
    required this.onClose,
    required this.onEditGroup,
    required this.onEditPax,
    required this.onComplete,
    required this.onCancel,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final colors = _statusColorsForGroup(group);
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(compact ? 18 : 16),
        boxShadow: const [
          BoxShadow(
            color: Color(0x26000000),
            blurRadius: 24,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                _StatusBadge(label: group.statusLabel, colors: colors),
                const SizedBox(width: 8),
                _PaymentBadge(paymentStatus: group.paymentStatus),
                const SizedBox(width: 8),
                _StatusBadge(label: '${group.paxCount} pax', colors: colors),
                const Spacer(),
                IconButton(onPressed: onClose, icon: const Icon(Icons.close)),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                CircleAvatar(
                  radius: 28,
                  backgroundColor: colors.accent.withValues(alpha: 0.78),
                  child: Text(
                    group.initials,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        group.customerName,
                        style: const TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.w900,
                          color: Color(0xFF111827),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        group.customerPhone,
                        style: const TextStyle(
                          fontSize: 13,
                          color: Color(0xFF6B7280),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 22),
            _SummaryItem(
              icon: Icons.groups_2_outlined,
              label: 'Pax',
              title: '${group.paxCount}',
            ),
            _SummaryItem(
              icon: Icons.spa_outlined,
              label: 'Services',
              title: '${group.serviceItems.length} services',
            ),
            _SummaryItem(
              icon: Icons.person_outline,
              label: 'Staff',
              title: group.therapistName,
            ),
            _SummaryItem(
              icon: Icons.meeting_room_outlined,
              label: 'Resources',
              title: group.roomName,
            ),
            _SummaryItem(
              icon: Icons.calendar_today_outlined,
              label: 'Date',
              title: DateFormat('EEEE, d MMMM yyyy').format(group.date),
            ),
            _SummaryItem(
              icon: Icons.schedule_outlined,
              label: 'Booked time',
              title: group.primary.bookedTimeRange,
              subtitle: group.primary.bufferAfterMinutes > 0
                  ? group.primary.cleanupUntilLabel
                  : null,
            ),
            if (group.primary.hasActualTiming)
              _SummaryItem(
                icon: Icons.play_circle_outline,
                label: 'Actual service time',
                title: group.primary.actualServiceTimeRange,
                subtitle: group.primary.actualServiceCompletionLabel,
              ),
            _SummaryItem(
              icon: Icons.payments_outlined,
              label: 'Price',
              title: 'RM ${group.price.toStringAsFixed(0)}',
            ),
            if (group.hasPayment) ...[
              _SummaryItem(
                icon: Icons.receipt_long_outlined,
                label: 'Receipt',
                title: group.receiptNumber,
              ),
              _SummaryItem(
                icon: Icons.verified_outlined,
                label: 'Payment',
                title:
                    '${_paymentMethodLabel(group.paymentMethod)} - ${group.paymentStatus.toLowerCase() == 'paid' ? 'Paid' : group.paymentStatus}',
                subtitle: 'RM ${group.paidAmount.toStringAsFixed(2)} paid',
              ),
            ],
            const SizedBox(height: 6),
            const Text(
              'Service Details',
              style: TextStyle(
                fontSize: 13,
                color: Color(0xFF111827),
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 10),
            for (var index = 0; index < group.appointments.length; index++)
              _GroupPaxDetailCard(
                index: index,
                appointment: group.appointments[index],
                onEdit: () => onEditPax(group.appointments[index]),
              ),
            const SizedBox(height: 12),
            if (onComplete != null)
              _PanelActionButton(
                icon: group.hasPayment
                    ? Icons.login_rounded
                    : Icons.point_of_sale_outlined,
                label: group.hasPayment
                    ? 'Check-In'
                    : 'Confirm Payment',
                color: const Color(0xFF15803D),
                onPressed: onComplete!,
              ),
            _PanelActionButton(
              icon: Icons.edit_outlined,
              label: 'Edit Appointment',
              color: const Color(0xFFF59E0B),
              onPressed: onEditGroup,
            ),
            if (onCancel != null)
              _PanelActionButton(
                icon: Icons.delete_outline,
                label: 'Cancel Booking',
                color: const Color(0xFFE53935),
                onPressed: onCancel!,
              ),
          ],
        ),
      ),
    );
  }
}

class _GroupPaxDetailCard extends StatelessWidget {
  final int index;
  final _ScheduleAppointment appointment;
  final VoidCallback onEdit;

  const _GroupPaxDetailCard({
    required this.index,
    required this.appointment,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: const Color(0xFFEFF6FF),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Text(
              '${index + 1}',
              style: const TextStyle(
                color: Color(0xFF2563EB),
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Pax ${index + 1} - ${appointment.customerName}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w900,
                    color: Color(0xFF111827),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  appointment.serviceName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF4B5563),
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '${appointment.therapistName} - ${appointment.roomName} - ${appointment.priceLabel} - ${appointment.cleanupUntilLabel}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF6B7280),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Edit pax',
            onPressed: onEdit,
            icon: const Icon(Icons.edit_outlined, size: 18),
            color: const Color(0xFFF59E0B),
          ),
        ],
      ),
    );
  }
}

_AppointmentStatusStyle _statusColors(_ScheduleAppointment appointment) {
  return _statusColorsFor(
    appointment.isPending,
    appointment.isCompleted,
    isInProgress: appointment.isInProgress,
    hasPayment: appointment.hasPayment,
    isLateArrival: appointment.isLateArrival,
    hasDelayWarning: appointment.hasDelayWarning,
  );
}

_AppointmentStatusStyle _statusColorsForGroup(_AppointmentGroup group) {
  return _statusColorsFor(
    group.isPending,
    group.isCompleted,
    isInProgress: group.isInProgress,
    hasPayment: group.hasPayment,
    isLateArrival: group.isLateArrival,
    hasDelayWarning: group.hasDelayWarning,
  );
}

_AppointmentStatusStyle _statusColorsFor(
  bool isPending,
  bool isCompleted, {
  bool isInProgress = false,
  bool hasPayment = false,
  bool isLateArrival = false,
  bool hasDelayWarning = false,
}) {
  if (isCompleted) {
    return const _AppointmentStatusStyle(
      accent: Color(0xFF059669),
      bg: Color(0xFFF0FDF4),
      border: Color(0xFF86EFAC),
    );
  }
  if (isInProgress) {
    return const _AppointmentStatusStyle(
      accent: Color(0xFFF97316),
      bg: Color(0xFFFFF7ED),
      border: Color(0xFFFED7AA),
    );
  }
  if (isLateArrival) {
    return const _AppointmentStatusStyle(
      accent: Color(0xFFB91C1C),
      bg: Color(0xFFFEF2F2),
      border: Color(0xFFFCA5A5),
    );
  }
  if (hasDelayWarning) {
    return const _AppointmentStatusStyle(
      accent: Color(0xFFD97706),
      bg: Color(0xFFFFFBEB),
      border: Color(0xFFFCD34D),
    );
  }
  // Paid but not yet started = Awaiting (online bookings) -> blue.
  if (isPending && hasPayment) {
    return const _AppointmentStatusStyle(
      accent: Color(0xFF2563EB),
      bg: Color(0xFFEFF6FF),
      border: Color(0xFF93C5FD),
    );
  }
  // Pending in-app booking that still needs payment -> purple.
  if (isPending) {
    return const _AppointmentStatusStyle(
      accent: Color(0xFF7C3AED),
      bg: Color(0xFFF5F3FF),
      border: Color(0xFFC4B5FD),
    );
  }
  return const _AppointmentStatusStyle(
    accent: Color(0xFF2563EB),
    bg: Color(0xFFEFF6FF),
    border: Color(0xFF93C5FD),
  );
}

Color _avatarColor(String value) {
  const colors = [
    Color(0xFF2563EB),
    Color(0xFF0F766E),
    Color(0xFF7C3AED),
    Color(0xFFDB2777),
    Color(0xFF0891B2),
    Color(0xFF059669),
  ];
  if (value.trim().isEmpty) return colors.first;
  final hash = value.codeUnits.fold<int>(0, (total, unit) => total + unit);
  return colors[hash % colors.length];
}

class _AppointmentSummaryPanel extends StatelessWidget {
  final _ScheduleAppointment appointment;
  final bool compact;
  final VoidCallback onClose;
  final VoidCallback onEdit;
  final VoidCallback? onComplete;
  final VoidCallback? onCancel;

  const _AppointmentSummaryPanel({
    required this.appointment,
    required this.onClose,
    required this.onEdit,
    required this.onComplete,
    required this.onCancel,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final colors = _statusColors(appointment);
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(compact ? 18 : 16),
        boxShadow: const [
          BoxShadow(
            color: Color(0x26000000),
            blurRadius: 24,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                _StatusBadge(label: appointment.statusLabel, colors: colors),
                const SizedBox(width: 8),
                _PaymentBadge(paymentStatus: appointment.paymentStatus),
                const Spacer(),
                IconButton(onPressed: onClose, icon: const Icon(Icons.close)),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                CircleAvatar(
                  radius: 28,
                  backgroundColor: colors.accent.withValues(alpha: 0.78),
                  child: Text(
                    appointment.initials,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        appointment.customerName,
                        style: const TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.w900,
                          color: Color(0xFF111827),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        appointment.customerPhone,
                        style: const TextStyle(
                          fontSize: 13,
                          color: Color(0xFF6B7280),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 22),
            _SummaryItem(
              icon: Icons.spa_outlined,
              label: 'Service',
              title: appointment.serviceName,
              subtitle: appointment.serviceDescription,
            ),
            _SummaryItem(
              icon: Icons.person_outline,
              label: 'Therapist',
              title: appointment.therapistName,
            ),
            _SummaryItem(
              icon: Icons.meeting_room_outlined,
              label: 'Room / Zone',
              title: appointment.roomName,
            ),
            _SummaryItem(
              icon: Icons.calendar_today_outlined,
              label: 'Date',
              title: DateFormat('EEEE, d MMMM yyyy').format(appointment.date),
            ),
            _SummaryItem(
              icon: Icons.schedule_outlined,
              label: 'Booked time',
              title: appointment.bookedTimeRange,
              subtitle: appointment.bufferAfterMinutes > 0
                  ? appointment.cleanupUntilLabel
                  : null,
            ),
            if (appointment.hasActualTiming)
              _SummaryItem(
                icon: Icons.play_circle_outline,
                label: 'Actual service time',
                title: appointment.actualServiceTimeRange,
                subtitle: appointment.actualServiceCompletionLabel,
              ),
            _SummaryItem(
              icon: Icons.payments_outlined,
              label: 'Price',
              title: 'RM ${appointment.price.toStringAsFixed(0)}',
            ),
            if (appointment.hasPayment) ...[
              _SummaryItem(
                icon: Icons.receipt_long_outlined,
                label: 'Receipt',
                title: appointment.receiptNumber,
              ),
              _SummaryItem(
                icon: Icons.verified_outlined,
                label: 'Payment',
                title:
                    '${_paymentMethodLabel(appointment.paymentMethod)} - ${appointment.paymentStatus.toLowerCase() == 'paid' ? 'Paid' : appointment.paymentStatus}',
                subtitle:
                    'RM ${appointment.paidAmount.toStringAsFixed(2)} paid',
              ),
            ],
            if (appointment.notes.trim().isNotEmpty) ...[
              const SizedBox(height: 4),
              const Text(
                'Notes',
                style: TextStyle(
                  fontSize: 12,
                  color: Color(0xFF6B7280),
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFFF3F4F6),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  appointment.notes,
                  style: const TextStyle(
                    fontSize: 13,
                    color: Color(0xFF374151),
                    height: 1.4,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 18),
            if (onComplete != null)
              _PanelActionButton(
                icon: appointment.hasPayment
                    ? Icons.login_rounded
                    : Icons.point_of_sale_outlined,
                label: appointment.hasPayment
                    ? 'Check-In'
                    : 'Confirm Payment',
                color: const Color(0xFF15803D),
                onPressed: onComplete!,
              ),
            _PanelActionButton(
              icon: Icons.edit_outlined,
              label: 'Edit Appointment',
              color: const Color(0xFFF59E0B),
              onPressed: onEdit,
            ),
            if (onCancel != null)
              _PanelActionButton(
                icon: Icons.delete_outline,
                label: 'Cancel Booking',
                color: const Color(0xFFE53935),
                onPressed: onCancel!,
              ),
          ],
        ),
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final String label;
  final _AppointmentStatusStyle colors;

  const _StatusBadge({required this.label, required this.colors});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: colors.accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: colors.accent,
          fontSize: 13,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

/// Payment status shown as its own badge, independent of the appointment
/// lifecycle status (a Completed booking can be Paid; a Confirmed one Unpaid).
class _PaymentBadge extends StatelessWidget {
  final String paymentStatus;

  const _PaymentBadge({required this.paymentStatus});

  @override
  Widget build(BuildContext context) {
    final normalized = paymentStatus.toLowerCase();
    late final Color accent;
    late final String label;
    switch (normalized) {
      case 'paid':
        accent = const Color(0xFF059669); // green
        label = 'Paid';
        break;
      case 'refunded':
        accent = const Color(0xFF6B7280); // grey
        label = 'Refunded';
        break;
      case 'voided':
        accent = const Color(0xFF6B7280); // grey
        label = 'Voided';
        break;
      default:
        accent = const Color(0xFFD97706); // amber
        label = 'Unpaid';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            normalized == 'paid'
                ? Icons.check_circle_outline
                : normalized == 'refunded' || normalized == 'voided'
                ? Icons.remove_circle_outline
                : Icons.schedule,
            size: 14,
            color: accent,
          ),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              color: accent,
              fontSize: 13,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}

class _TimelineStatusBadge extends StatelessWidget {
  final String label;
  final _AppointmentStatusStyle colors;
  final bool compact;

  const _TimelineStatusBadge({
    required this.label,
    required this.colors,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final dotSize = compact ? 6.0 : 7.0;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 8 : 10,
        vertical: compact ? 5 : 6,
      ),
      decoration: BoxDecoration(
        color: colors.accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: colors.accent.withValues(alpha: 0.22)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: dotSize,
            height: dotSize,
            decoration: BoxDecoration(
              color: colors.accent,
              shape: BoxShape.circle,
            ),
          ),
          SizedBox(width: compact ? 5 : 6),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: compact ? 10 : 11,
              color: colors.accent,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}

class _SummaryItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final String title;
  final String? subtitle;

  const _SummaryItem({
    required this.icon,
    required this.label,
    required this.title,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: const Color(0xFF4B5563)),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF6B7280),
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 14,
                    color: Color(0xFF111827),
                    fontWeight: FontWeight.w900,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF6B7280),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PanelActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onPressed;

  const _PanelActionButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: SizedBox(
        width: double.infinity,
        height: 44,
        child: OutlinedButton.icon(
          onPressed: onPressed,
          icon: Icon(icon, size: 18),
          label: Text(label),
          style: OutlinedButton.styleFrom(
            backgroundColor: Colors.white,
            foregroundColor: color,
            side: BorderSide(color: color.withValues(alpha: 0.72)),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            textStyle: const TextStyle(fontWeight: FontWeight.w900),
          ),
        ),
      ),
    );
  }
}

class _AppointmentCheckoutSheet extends StatefulWidget {
  final _ScheduleAppointment appointment;

  const _AppointmentCheckoutSheet({required this.appointment});

  @override
  State<_AppointmentCheckoutSheet> createState() =>
      _AppointmentCheckoutSheetState();
}

class _AppointmentCheckoutSheetState extends State<_AppointmentCheckoutSheet> {
  final _appointmentRepository = AppointmentRepository();
  final _businessSettingsRepository = BusinessSettingsRepository();
  final _commissionRepository = CommissionRepository();
  late final TextEditingController _name;
  late final TextEditingController _phone;
  late final String _receiptNumber;
  String? _paymentMethod;
  bool _saveCustomerProfile = false;
  bool _saving = false;
  BusinessRuleSettings _businessSettings = BusinessRuleSettings.defaults();

  PriceBreakdown get _priceBreakdown =>
      _businessSettings.priceBreakdown(widget.appointment.price);

  double get _servicePrice => _priceBreakdown.servicePrice;
  double get _sstAmount => _priceBreakdown.sstAmount;
  double get _totalAmount => _priceBreakdown.totalAmount;

  bool get _canConfirm {
    if (_paymentMethod == null || _saving) return false;
    return true;
  }

  bool get _hasMemberDetails {
    final name = _name.text.trim();
    final phone = _phone.text.trim();
    return !_isGuestPlaceholder(name) && phone.isNotEmpty;
  }

  @override
  void initState() {
    super.initState();
    _receiptNumber = _generateReceiptNumber();
    _saveCustomerProfile = widget.appointment.isGuestAccount;
    _name = TextEditingController(
      text: _isGuestPlaceholder(widget.appointment.customerName)
          ? 'Guest'
          : widget.appointment.customerName,
    )..addListener(_refresh);
    _phone = TextEditingController(
      text: widget.appointment.customerPhone.trim() == '-'
          ? ''
          : widget.appointment.customerPhone,
    )..addListener(_refresh);
    _loadBusinessSettings();
  }

  @override
  void dispose() {
    _name.removeListener(_refresh);
    _phone.removeListener(_refresh);
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  bool _isGuestPlaceholder(String value) {
    final normalized = value.trim().toLowerCase();
    return widget.appointment.isGuestAccount &&
        (normalized.isEmpty ||
            normalized == 'guest' ||
            normalized == 'guest account' ||
            normalized == 'walk-in guest');
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  Future<void> _loadBusinessSettings() async {
    try {
      final settings = await _businessSettingsRepository.getActiveSettings();
      if (mounted) setState(() => _businessSettings = settings);
    } catch (_) {
      if (mounted) {
        setState(() => _businessSettings = BusinessRuleSettings.defaults());
      }
    }
  }

  String _resolvedCustomerName() {
    final value = _name.text.trim();
    if (value.isNotEmpty) return value;
    return widget.appointment.isGuestAccount
        ? 'Guest'
        : widget.appointment.customerName;
  }

  Future<void> _confirmCheckout() async {
    if (!_canConfirm) return;
    setState(() => _saving = true);

    try {
      var customerId = widget.appointment.customerId;
      final customerName = _resolvedCustomerName();
      final counterStaff = await _commissionRepository
          .getAvailableCounterStaff();
      final shouldSaveCustomerProfile =
          widget.appointment.isGuestAccount &&
          _saveCustomerProfile &&
          _hasMemberDetails;
      final serviceStartedAt = DateTime.now();
      if (!mounted) return;
      final lateStart = await _lateStartDecision(
        context: context,
        appointment: widget.appointment,
        settings: _businessSettings,
        startedAt: serviceStartedAt,
      );

      await _appointmentRepository.checkoutAppointment(
        appointmentId: widget.appointment.id,
        newCustomerValues: shouldSaveCustomerProfile
            ? {
                'name': customerName,
                'phone': _phone.text.trim(),
                'gender': '',
                'joinDate': DateFormat('yyyy-MM-dd').format(DateTime.now()),
                'notes': 'Created from appointment checkout',
              }
            : null,
        appointmentUpdates: {
          'customerId': customerId,
          ...widget.appointment.serviceStartUpdates(
            serviceStartedAt,
            adjustedEndAt: lateStart.adjustedEndAt,
            allowLateExtensionOverlap: lateStart.allowLateExtensionOverlap,
          ),
        },
        transactionValues: {
          'customerId': customerId,
          'customerName': customerName,
          'customerPhone': _phone.text.trim().isNotEmpty
              ? _phone.text.trim()
              : widget.appointment.customerPhone,
          if (counterStaff != null) ...{
            'counterStaffId': counterStaff['id'],
            'counterStaffName': counterStaff['name'],
          },
          'servicePrice': _servicePrice,
          'sstAmount': _sstAmount,
          'totalAmount': _totalAmount,
          'source': 'appointment',
          'paymentMethod': _paymentMethod,
          'paymentStatus': 'paid',
          'receiptNumber': _receiptNumber,
        },
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Payment recorded - service is now in progress'),
          backgroundColor: Color(0xFF1B6B72),
          behavior: SnackBarBehavior.floating,
        ),
      );
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Unable to confirm booking: ${friendlyErrorMessage(e)}'),
          backgroundColor: const Color(0xFFE53935),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return SafeArea(
      top: false,
      child: Align(
        alignment: Alignment.bottomCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 620,
            maxHeight: MediaQuery.of(context).size.height * 0.92,
          ),
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 12),
            padding: EdgeInsets.fromLTRB(20, 18, 20, bottomInset + 20),
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Confirm Payment',
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w900,
                                color: Color(0xFF111827),
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              '#$_receiptNumber',
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF6B7280),
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        onPressed: _saving
                            ? null
                            : () => Navigator.pop(context, false),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  const Text(
                    'Customer Details',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w900,
                      color: Color(0xFF1A1A2E),
                    ),
                  ),
                  const SizedBox(height: 10),
                  _EditField(label: 'Name', controller: _name),
                  const SizedBox(height: 12),
                  _EditField(
                    label: 'Phone',
                    controller: _phone,
                    keyboardType: TextInputType.phone,
                  ),
                  if (widget.appointment.isGuestAccount) ...[
                    const SizedBox(height: 8),
                    CheckboxListTile(
                      value: _saveCustomerProfile,
                      onChanged: _saving
                          ? null
                          : (value) => setState(
                              () => _saveCustomerProfile = value ?? false,
                            ),
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      activeColor: const Color(0xFF1B6B72),
                      title: const Text(
                        'Save as customer profile',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF1A1A2E),
                        ),
                      ),
                      subtitle: const Text(
                        'A member is created only when name and phone are filled.',
                        style: TextStyle(
                          fontSize: 12,
                          color: Color(0xFF6B7280),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  _CheckoutRecapCard(appointment: widget.appointment),
                  const SizedBox(height: 16),
                  _CheckoutPriceCard(
                    servicePrice: _servicePrice,
                    sstAmount: _sstAmount,
                    totalAmount: _totalAmount,
                    sstLabel: _businessSettings.sstLabel,
                  ),
                  const SizedBox(height: 18),
                  const Text(
                    'Payment Method',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w900,
                      color: Color(0xFF1A1A2E),
                    ),
                  ),
                  const SizedBox(height: 12),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final compact = constraints.maxWidth < 460;
                      final width = compact
                          ? constraints.maxWidth
                          : (constraints.maxWidth - 36) / 4;
                      return Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          SizedBox(
                            width: width,
                            child: _CheckoutPaymentMethodCard(
                              icon: Icons.payments_outlined,
                              label: 'Cash',
                              isSelected: _paymentMethod == 'cash',
                              onTap: () =>
                                  setState(() => _paymentMethod = 'cash'),
                            ),
                          ),
                          SizedBox(
                            width: width,
                            child: _CheckoutPaymentMethodCard(
                              icon: Icons.qr_code_2_outlined,
                              label: 'QR Code',
                              isSelected: _paymentMethod == 'qr_code',
                              onTap: () =>
                                  setState(() => _paymentMethod = 'qr_code'),
                            ),
                          ),
                          SizedBox(
                            width: width,
                            child: _CheckoutPaymentMethodCard(
                              icon: Icons.credit_card_outlined,
                              label: 'Credit Card',
                              isSelected: _paymentMethod == 'credit_card',
                              onTap: () => setState(
                                () => _paymentMethod = 'credit_card',
                              ),
                            ),
                          ),
                          SizedBox(
                            width: width,
                            child: _CheckoutPaymentMethodCard(
                              icon: Icons.credit_card,
                              label: 'Debit Card',
                              isSelected: _paymentMethod == 'debit_card',
                              onTap: () => setState(
                                () => _paymentMethod = 'debit_card',
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 22),
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: FilledButton.icon(
                      onPressed: _canConfirm ? _confirmCheckout : null,
                      icon: _saving
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.check, size: 18),
                      label: const Text('Confirm Payment & Start Service'),
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF1B6B72),
                        disabledBackgroundColor: const Color(0xFFBDBDBD),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        textStyle: const TextStyle(fontWeight: FontWeight.w900),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AppointmentGroupCheckoutSheet extends StatefulWidget {
  final _AppointmentGroup group;

  const _AppointmentGroupCheckoutSheet({required this.group});

  @override
  State<_AppointmentGroupCheckoutSheet> createState() =>
      _AppointmentGroupCheckoutSheetState();
}

class _AppointmentGroupCheckoutSheetState
    extends State<_AppointmentGroupCheckoutSheet> {
  final _appointmentRepository = AppointmentRepository();
  final _businessSettingsRepository = BusinessSettingsRepository();
  final _commissionRepository = CommissionRepository();
  late final TextEditingController _name;
  late final TextEditingController _phone;
  late final String _receiptNumber;
  String? _paymentMethod;
  bool _saveCustomerProfile = false;
  bool _saving = false;
  BusinessRuleSettings _businessSettings = BusinessRuleSettings.defaults();

  PriceBreakdown get _priceBreakdown =>
      _businessSettings.priceBreakdown(widget.group.price);

  double get _servicePrice => _priceBreakdown.servicePrice;
  double get _sstAmount => _priceBreakdown.sstAmount;
  double get _totalAmount => _priceBreakdown.totalAmount;

  bool get _canConfirm => _paymentMethod != null && !_saving;

  bool get _hasMemberDetails {
    final name = _name.text.trim();
    final phone = _phone.text.trim();
    return !_isGuestPlaceholder(name) && phone.isNotEmpty;
  }

  @override
  void initState() {
    super.initState();
    _receiptNumber = _generateReceiptNumber();
    _saveCustomerProfile = widget.group.isGuestAccount;
    _name = TextEditingController(
      text: _isGuestPlaceholder(widget.group.customerName)
          ? 'Guest'
          : widget.group.customerName,
    )..addListener(_refresh);
    _phone = TextEditingController(
      text: widget.group.customerPhone.trim() == '-'
          ? ''
          : widget.group.customerPhone,
    )..addListener(_refresh);
    _loadBusinessSettings();
  }

  @override
  void dispose() {
    _name.removeListener(_refresh);
    _phone.removeListener(_refresh);
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  bool _isGuestPlaceholder(String value) {
    final normalized = value.trim().toLowerCase();
    return widget.group.isGuestAccount &&
        (normalized.isEmpty ||
            normalized == 'guest' ||
            normalized == 'guest account' ||
            normalized == 'walk-in guest');
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  Future<void> _loadBusinessSettings() async {
    try {
      final settings = await _businessSettingsRepository.getActiveSettings();
      if (mounted) setState(() => _businessSettings = settings);
    } catch (_) {
      if (mounted) {
        setState(() => _businessSettings = BusinessRuleSettings.defaults());
      }
    }
  }

  String _resolvedCustomerName() {
    final value = _name.text.trim();
    if (value.isNotEmpty) return value;
    return widget.group.isGuestAccount ? 'Guest' : widget.group.customerName;
  }

  Future<void> _confirmCheckout() async {
    if (!_canConfirm) return;
    setState(() => _saving = true);

    try {
      var customerId = widget.group.primary.customerId;
      final customerName = _resolvedCustomerName();
      final counterStaff = await _commissionRepository
          .getAvailableCounterStaff();
      final shouldSaveCustomerProfile =
          widget.group.isGuestAccount &&
          _saveCustomerProfile &&
          _hasMemberDetails;
      final serviceStartedAt = DateTime.now();
      if (!mounted) return;
      final lateStartByAppointmentId = <String, _LateStartDecision>{};
      for (final appointment in widget.group.appointments) {
        if (!mounted) return;
        lateStartByAppointmentId[appointment.id] = await _lateStartDecision(
          context: context,
          appointment: appointment,
          settings: _businessSettings,
          startedAt: serviceStartedAt,
        );
        if (!mounted) return;
      }

      await _appointmentRepository.checkoutAppointmentGroup(
        appointmentGroupId: widget.group.appointmentGroupId,
        appointmentIds: widget.group.appointments.map((a) => a.id).toList(),
        newCustomerValues: shouldSaveCustomerProfile
            ? {
                'name': customerName,
                'phone': _phone.text.trim(),
                'gender': '',
                'joinDate': DateFormat('yyyy-MM-dd').format(DateTime.now()),
                'notes': 'Created from group appointment checkout',
              }
            : null,
        appointmentUpdates: {'customerId': customerId},
        appointmentUpdatesById: {
          for (final appointment in widget.group.appointments)
            appointment.id: appointment.serviceStartUpdates(
              serviceStartedAt,
              adjustedEndAt:
                  lateStartByAppointmentId[appointment.id]?.adjustedEndAt,
              allowLateExtensionOverlap:
                  lateStartByAppointmentId[appointment.id]
                      ?.allowLateExtensionOverlap ??
                  false,
            ),
        },
        transactionValues: {
          'customerId': customerId,
          'customerName': customerName,
          'customerPhone': _phone.text.trim().isNotEmpty
              ? _phone.text.trim()
              : widget.group.customerPhone,
          if (counterStaff != null) ...{
            'counterStaffId': counterStaff['id'],
            'counterStaffName': counterStaff['name'],
          },
          'servicePrice': _servicePrice,
          'sstAmount': _sstAmount,
          'totalAmount': _totalAmount,
          'source': 'appointment',
          'paymentMethod': _paymentMethod,
          'paymentStatus': 'paid',
          'receiptNumber': _receiptNumber,
        },
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Group payment recorded - services are now in progress',
          ),
          backgroundColor: Color(0xFF1B6B72),
          behavior: SnackBarBehavior.floating,
        ),
      );
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Unable to confirm group booking: ${friendlyErrorMessage(e)}',
          ),
          backgroundColor: const Color(0xFFE53935),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return SafeArea(
      top: false,
      child: Align(
        alignment: Alignment.bottomCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 620,
            maxHeight: MediaQuery.of(context).size.height * 0.92,
          ),
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 12),
            padding: EdgeInsets.fromLTRB(20, 18, 20, bottomInset + 20),
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Confirm Group Payment',
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w900,
                                color: Color(0xFF111827),
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              '#$_receiptNumber',
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF6B7280),
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        onPressed: _saving
                            ? null
                            : () => Navigator.pop(context, false),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  const Text(
                    'Customer Details',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w900,
                      color: Color(0xFF1A1A2E),
                    ),
                  ),
                  const SizedBox(height: 10),
                  _EditField(label: 'Name', controller: _name),
                  const SizedBox(height: 12),
                  _EditField(
                    label: 'Phone',
                    controller: _phone,
                    keyboardType: TextInputType.phone,
                  ),
                  if (widget.group.isGuestAccount) ...[
                    const SizedBox(height: 8),
                    CheckboxListTile(
                      value: _saveCustomerProfile,
                      onChanged: _saving
                          ? null
                          : (value) => setState(
                              () => _saveCustomerProfile = value ?? false,
                            ),
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      activeColor: const Color(0xFF1B6B72),
                      title: const Text(
                        'Save as customer profile',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF1A1A2E),
                        ),
                      ),
                      subtitle: const Text(
                        'A member is created only when name and phone are filled.',
                        style: TextStyle(
                          fontSize: 12,
                          color: Color(0xFF6B7280),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  _GroupCheckoutRecapCard(group: widget.group),
                  const SizedBox(height: 16),
                  _CheckoutPriceCard(
                    servicePrice: _servicePrice,
                    sstAmount: _sstAmount,
                    totalAmount: _totalAmount,
                    sstLabel: _businessSettings.sstLabel,
                  ),
                  const SizedBox(height: 18),
                  const Text(
                    'Payment Method',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w900,
                      color: Color(0xFF1A1A2E),
                    ),
                  ),
                  const SizedBox(height: 12),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final compact = constraints.maxWidth < 460;
                      final width = compact
                          ? constraints.maxWidth
                          : (constraints.maxWidth - 36) / 4;
                      return Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          SizedBox(
                            width: width,
                            child: _CheckoutPaymentMethodCard(
                              icon: Icons.payments_outlined,
                              label: 'Cash',
                              isSelected: _paymentMethod == 'cash',
                              onTap: () =>
                                  setState(() => _paymentMethod = 'cash'),
                            ),
                          ),
                          SizedBox(
                            width: width,
                            child: _CheckoutPaymentMethodCard(
                              icon: Icons.qr_code_2_outlined,
                              label: 'QR Code',
                              isSelected: _paymentMethod == 'qr_code',
                              onTap: () =>
                                  setState(() => _paymentMethod = 'qr_code'),
                            ),
                          ),
                          SizedBox(
                            width: width,
                            child: _CheckoutPaymentMethodCard(
                              icon: Icons.credit_card_outlined,
                              label: 'Credit Card',
                              isSelected: _paymentMethod == 'credit_card',
                              onTap: () => setState(
                                () => _paymentMethod = 'credit_card',
                              ),
                            ),
                          ),
                          SizedBox(
                            width: width,
                            child: _CheckoutPaymentMethodCard(
                              icon: Icons.credit_card,
                              label: 'Debit Card',
                              isSelected: _paymentMethod == 'debit_card',
                              onTap: () => setState(
                                () => _paymentMethod = 'debit_card',
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 22),
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: FilledButton.icon(
                      onPressed: _canConfirm ? _confirmCheckout : null,
                      icon: _saving
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.check, size: 18),
                      label: const Text('Confirm Payment & Start Services'),
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF1B6B72),
                        disabledBackgroundColor: const Color(0xFFBDBDBD),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        textStyle: const TextStyle(fontWeight: FontWeight.w900),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CheckoutRecapCard extends StatelessWidget {
  final _ScheduleAppointment appointment;

  const _CheckoutRecapCard({required this.appointment});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  appointment.serviceName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w900,
                    color: Color(0xFF1A1A2E),
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFFE8F5F5),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  appointment.bufferAfterMinutes > 0
                      ? '${appointment.durationMinutes} + ${appointment.bufferAfterMinutes} min'
                      : '${appointment.durationMinutes} min',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF1B6B72),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '${appointment.therapistName} - ${appointment.roomName}',
            style: const TextStyle(fontSize: 13, color: Color(0xFF6B7280)),
          ),
          const SizedBox(height: 3),
          Text(
            '${DateFormat('EEE, d MMM yyyy').format(appointment.date)} - ${appointment.timeRange}',
            style: const TextStyle(fontSize: 13, color: Color(0xFF6B7280)),
          ),
          const SizedBox(height: 3),
          Text(
            appointment.cleanupUntilLabel,
            style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
          ),
        ],
      ),
    );
  }
}

class _GroupCheckoutRecapCard extends StatelessWidget {
  final _AppointmentGroup group;

  const _GroupCheckoutRecapCard({required this.group});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${group.paxCount} pax services',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w900,
                    color: Color(0xFF1A1A2E),
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFFE8F5F5),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  group.timeRange,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF1B6B72),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          for (var index = 0; index < group.appointments.length; index++)
            Padding(
              padding: EdgeInsets.only(
                bottom: index == group.appointments.length - 1 ? 0 : 8,
              ),
              child: _GroupCheckoutPaxRow(
                index: index,
                appointment: group.appointments[index],
              ),
            ),
        ],
      ),
    );
  }
}

class _GroupCheckoutPaxRow extends StatelessWidget {
  final int index;
  final _ScheduleAppointment appointment;

  const _GroupCheckoutPaxRow({required this.index, required this.appointment});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Pax ${index + 1}',
          style: const TextStyle(
            fontSize: 12,
            color: Color(0xFF2563EB),
            fontWeight: FontWeight.w900,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${appointment.customerName} - ${appointment.serviceName}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  color: Color(0xFF111827),
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '${appointment.therapistName} - ${appointment.roomName}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
              ),
              const SizedBox(height: 2),
              Text(
                appointment.bufferAfterMinutes > 0
                    ? '${appointment.durationMinutes} min service + ${appointment.bufferAfterMinutes} min cleanup'
                    : '${appointment.durationMinutes} min service',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280)),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Text(
          appointment.priceLabel,
          style: const TextStyle(
            fontSize: 12,
            color: Color(0xFF111827),
            fontWeight: FontWeight.w900,
          ),
        ),
      ],
    );
  }
}

class _CheckoutPriceCard extends StatelessWidget {
  final double servicePrice;
  final double sstAmount;
  final double totalAmount;
  final String sstLabel;

  const _CheckoutPriceCard({
    required this.servicePrice,
    required this.sstAmount,
    required this.totalAmount,
    required this.sstLabel,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFEEEEEE)),
      ),
      child: Column(
        children: [
          _CheckoutPriceRow('Service', 'RM ${servicePrice.toStringAsFixed(2)}'),
          const SizedBox(height: 8),
          _CheckoutPriceRow(sstLabel, 'RM ${sstAmount.toStringAsFixed(2)}'),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 10),
            child: Divider(color: Color(0xFFEEEEEE), height: 1),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Total',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w900,
                  color: Color(0xFF1A1A2E),
                ),
              ),
              Text(
                'RM ${totalAmount.toStringAsFixed(2)}',
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                  color: Color(0xFF1B6B72),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CheckoutPriceRow extends StatelessWidget {
  final String label;
  final String value;

  const _CheckoutPriceRow(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 13, color: Color(0xFF6B6B6B)),
        ),
        Text(
          value,
          style: const TextStyle(fontSize: 13, color: Color(0xFF1A1A2E)),
        ),
      ],
    );
  }
}

class _CheckoutPaymentMethodCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const _CheckoutPaymentMethodCard({
    required this.icon,
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF1B6B72) : Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected
                ? const Color(0xFF1B6B72)
                : const Color(0xFFEEEEEE),
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Column(
          children: [
            Icon(
              icon,
              size: 24,
              color: isSelected ? Colors.white : const Color(0xFF6B6B6B),
            ),
            const SizedBox(height: 7),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color: isSelected ? Colors.white : const Color(0xFF1A1A2E),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AppointmentEditSheet extends StatefulWidget {
  final _ScheduleAppointment appointment;

  const _AppointmentEditSheet({required this.appointment});

  @override
  State<_AppointmentEditSheet> createState() => _AppointmentEditSheetState();
}

class _AppointmentEditSheetState extends State<_AppointmentEditSheet> {
  final _appointmentRepository = AppointmentRepository();
  late final TextEditingController _start;
  late final TextEditingController _end;
  late final TextEditingController _notes;
  late final TextEditingController _price;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _start = TextEditingController(text: widget.appointment.startTime);
    _end = TextEditingController(text: widget.appointment.endTime);
    _notes = TextEditingController(text: widget.appointment.notes);
    _price = TextEditingController(
      text: widget.appointment.price.toStringAsFixed(0),
    );
  }

  @override
  void dispose() {
    _start.dispose();
    _end.dispose();
    _notes.dispose();
    _price.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final startTime = _normalizeEditTime(_start.text);
    final endTime = _normalizeEditTime(_end.text);
    final price =
        double.tryParse(_price.text.trim()) ?? widget.appointment.price;

    if (startTime == null || endTime == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Use a valid time, for example 09:30'),
          backgroundColor: Color(0xFFE53935),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    setState(() => _saving = true);
    try {
      if (widget.appointment.therapistId.isEmpty ||
          widget.appointment.roomId.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Appointment needs staff and room before saving.'),
            backgroundColor: Color(0xFFE53935),
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }

      final result = await CspService.updateAppointment(
        appointmentId: widget.appointment.id,
        therapistId: widget.appointment.therapistId,
        roomId: widget.appointment.roomId,
        date: widget.appointment.dateKey,
        startTime: startTime,
        endTime: endTime,
      );

      if (!mounted) return;
      if (!result.success) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(result.message),
            backgroundColor: const Color(0xFFE53935),
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }

      await _appointmentRepository.updateAppointment(widget.appointment.id, {
        'notes': _notes.text.trim(),
        'totalPrice': price,
      });
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Unable to save appointment: ${friendlyErrorMessage(e)}',
          ),
          backgroundColor: const Color(0xFFE53935),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String? _normalizeEditTime(String value) {
    final raw = value.trim();
    final match = RegExp(r'^(\d{1,2}):(\d{2})(?::(\d{2}))?$').firstMatch(raw);
    if (match == null) return null;

    final hour = int.tryParse(match.group(1) ?? '');
    final minute = int.tryParse(match.group(2) ?? '');
    final second = int.tryParse(match.group(3) ?? '0');
    if (hour == null ||
        minute == null ||
        second == null ||
        hour > 23 ||
        minute > 59 ||
        second > 59) {
      return null;
    }

    return '${hour.toString().padLeft(2, '0')}:'
        '${minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(
        20,
        18,
        20,
        MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Edit Appointment',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w900,
                color: Color(0xFF111827),
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: _EditField(label: 'Start', controller: _start),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _EditField(label: 'End', controller: _end),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _EditField(
              label: 'Price',
              controller: _price,
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 12),
            _EditField(label: 'Notes', controller: _notes, maxLines: 3),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: FilledButton(
                onPressed: _saving ? null : _save,
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF2F7D59),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                child: Text(_saving ? 'Saving...' : 'Save Changes'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EditField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final int maxLines;
  final TextInputType? keyboardType;

  const _EditField({
    required this.label,
    required this.controller,
    this.maxLines = 1,
    this.keyboardType,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      maxLines: maxLines,
      keyboardType: keyboardType,
      decoration: InputDecoration(
        labelText: label,
        filled: true,
        fillColor: const Color(0xFFF6FAF5),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: Color(0xFFE5E7EB)),
        ),
      ),
    );
  }
}

class _ScheduleLoading extends StatelessWidget {
  const _ScheduleLoading();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: CircularProgressIndicator(color: Color(0xFF2F7D59)),
    );
  }
}

class _ScheduleError extends StatelessWidget {
  final VoidCallback onRetry;

  const _ScheduleError({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, color: Color(0xFFE53935), size: 30),
          const SizedBox(height: 10),
          const Text(
            'Unable to load appointments.',
            style: TextStyle(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 12),
          OutlinedButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}

class _ScheduleEmptyState extends StatelessWidget {
  const _ScheduleEmptyState();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: const Column(
        children: [
          Icon(
            Icons.event_available_outlined,
            color: Color(0xFF2F7D59),
            size: 34,
          ),
          SizedBox(height: 10),
          Text(
            'No appointments for this day',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w900,
              color: Color(0xFF111827),
            ),
          ),
          SizedBox(height: 4),
          Text(
            'New bookings will appear here automatically.',
            style: TextStyle(color: Color(0xFF6B7280)),
          ),
        ],
      ),
    );
  }
}
