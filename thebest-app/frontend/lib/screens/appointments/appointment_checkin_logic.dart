bool isFixedTherapistAssignmentSource(String source) {
  final normalized = source.trim().toLowerCase();
  return normalized == 'specific_customer_request' ||
      normalized == 'manual_override';
}

String? therapistIdForFinalStart({
  required String assignmentSource,
  required String? selectedTherapistId,
}) {
  if (!isFixedTherapistAssignmentSource(assignmentSource)) return null;
  final therapistId = selectedTherapistId?.trim() ?? '';
  return therapistId.isEmpty ? null : therapistId;
}

/// Appointment details should show the amount actually collected whenever a
/// paid transaction exists. [scheduledAmount] can be the pre-SST service net
/// in exclusive-tax mode, so it is only the fallback for unpaid appointments.
double appointmentChargedTotal({
  required double scheduledAmount,
  required double paidAmount,
}) {
  return paidAmount > 0.005 ? paidAmount : scheduledAmount;
}

List<Map<String, dynamic>> appointmentAddOnItems({
  required List<Map<String, dynamic>> currentItems,
  required List<Map<String, dynamic>> paidItems,
}) {
  return _itemsNotCoveredBy(
    currentItems: currentItems,
    coveredItems: paidItems,
    markAsAddOn: true,
  );
}

List<Map<String, dynamic>> appointmentUnpaidItems({
  required List<Map<String, dynamic>> currentItems,
  required List<Map<String, dynamic>> paidItems,
}) {
  return _itemsNotCoveredBy(
    currentItems: currentItems,
    coveredItems: paidItems,
    markAsAddOn: false,
  );
}

List<Map<String, dynamic>> transactionItemsForAppointment({
  required Map<String, dynamic> transaction,
  required String appointmentId,
  List<Map<String, dynamic>>? fallbackAppointmentItems,
}) {
  final rawItems = _rawServiceItems(transaction['serviceItems']);
  final transactionAppointmentId =
      transaction['appointmentId']?.toString() ??
      transaction['appointment_id']?.toString() ??
      '';
  if (transactionAppointmentId == appointmentId) return rawItems;

  final matchedItems = rawItems.where((item) {
    final itemAppointmentId =
        item['appointmentId']?.toString() ??
        item['appointment_id']?.toString() ??
        '';
    return itemAppointmentId == appointmentId;
  }).toList();
  if (matchedItems.isNotEmpty) return matchedItems;

  final groupId =
      transaction['appointmentGroupId']?.toString() ??
      transaction['appointment_group_id']?.toString() ??
      '';
  final hasAnyAppointmentTags = rawItems.any((item) {
    final taggedId =
        item['appointmentId']?.toString() ??
        item['appointment_id']?.toString() ??
        '';
    return taggedId.isNotEmpty;
  });
  if (groupId.isNotEmpty &&
      !hasAnyAppointmentTags &&
      fallbackAppointmentItems != null &&
      fallbackAppointmentItems.isNotEmpty) {
    // Legacy group receipts stored every pax line on one transaction but did
    // not persist the appointment ID per line. The appointment's own service
    // snapshot identifies the matching subset of that original paid group.
    // Explicit later add-ons are excluded because they have their own receipt.
    final remaining = [...rawItems];
    final fallbackMatches = <Map<String, dynamic>>[];
    for (final appointmentItem in fallbackAppointmentItems) {
      final lineType =
          appointmentItem['lineType']?.toString().toLowerCase() ??
          appointmentItem['line_type']?.toString().toLowerCase() ??
          '';
      if (lineType == 'addon' || lineType == 'add_on') continue;
      final itemId = serviceItemId(appointmentItem);
      final matchIndex = remaining.indexWhere(
        (candidate) => serviceItemId(candidate) == itemId,
      );
      if (matchIndex >= 0) {
        fallbackMatches.add(remaining.removeAt(matchIndex));
      }
    }
    return fallbackMatches;
  }

  return matchedItems;
}

double transactionAmountForAppointment({
  required Map<String, dynamic> transaction,
  required String appointmentId,
  List<Map<String, dynamic>>? fallbackAppointmentItems,
}) {
  final totalAmount = _asDouble(
    transaction['totalAmount'] ?? transaction['total_amount'],
  );
  final transactionAppointmentId =
      transaction['appointmentId']?.toString() ??
      transaction['appointment_id']?.toString() ??
      '';
  if (transactionAppointmentId == appointmentId) return totalAmount;

  final allItems = _rawServiceItems(transaction['serviceItems']);
  final appointmentItems = transactionItemsForAppointment(
    transaction: transaction,
    appointmentId: appointmentId,
    fallbackAppointmentItems: fallbackAppointmentItems,
  );
  if (appointmentItems.isEmpty) return 0;
  if (allItems.isEmpty) return 0;
  final allItemsTotal = allItems.fold<double>(
    0,
    (total, item) => total + _serviceItemPrice(item),
  );
  final appointmentItemsTotal = appointmentItems.fold<double>(
    0,
    (total, item) => total + _serviceItemPrice(item),
  );
  if (allItemsTotal <= 0) {
    return totalAmount / allItems.length;
  }
  return totalAmount * appointmentItemsTotal / allItemsTotal;
}

List<Map<String, dynamic>> _itemsNotCoveredBy({
  required List<Map<String, dynamic>> currentItems,
  required List<Map<String, dynamic>> coveredItems,
  required bool markAsAddOn,
}) {
  final coveredCounts = <String, int>{};
  for (final item in coveredItems) {
    final id = serviceItemId(item);
    if (id.isNotEmpty) coveredCounts[id] = (coveredCounts[id] ?? 0) + 1;
  }

  final remainingItems = <Map<String, dynamic>>[];
  for (final item in currentItems) {
    final id = serviceItemId(item);
    final remaining = coveredCounts[id] ?? 0;
    final isExplicitAddOn =
        item['lineType']?.toString().trim().toLowerCase() == 'add_on';

    // An explicit add-on remains part of the appointment's add-on history
    // after payment so the UI can keep showing it as paid and locked. Consume
    // its matching paid item, but do not remove it from the display list.
    // The unpaid calculation uses markAsAddOn=false and still removes it.
    if (markAsAddOn && isExplicitAddOn) {
      if (remaining > 0) coveredCounts[id] = remaining - 1;
      remainingItems.add({...item, 'lineType': 'add_on'});
      continue;
    }
    if (remaining > 0) {
      coveredCounts[id] = remaining - 1;
      continue;
    }
    remainingItems.add(markAsAddOn ? {...item, 'lineType': 'add_on'} : {...item});
  }
  return remainingItems;
}

List<Map<String, dynamic>> _rawServiceItems(Object? value) {
  if (value is! List) return const [];
  return value
      .whereType<Map>()
      .map((item) => Map<String, dynamic>.from(item))
      .toList();
}

String serviceItemId(Map<String, dynamic> item) =>
    item['id']?.toString() ??
    item['serviceId']?.toString() ??
    item['service_id']?.toString() ??
    '';

double _serviceItemPrice(Map<String, dynamic> item) => _asDouble(
  item['price'] ?? item['displayPrice'] ?? item['display_price'],
);

double _asDouble(Object? value) {
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString() ?? '') ?? 0;
}
