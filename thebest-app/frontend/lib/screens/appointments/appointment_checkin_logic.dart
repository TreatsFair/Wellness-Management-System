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
}) {
  final rawItems = _rawServiceItems(transaction['serviceItems']);
  final transactionAppointmentId =
      transaction['appointmentId']?.toString() ??
      transaction['appointment_id']?.toString() ??
      '';
  if (transactionAppointmentId == appointmentId) return rawItems;

  return rawItems.where((item) {
    final itemAppointmentId =
        item['appointmentId']?.toString() ??
        item['appointment_id']?.toString() ??
        '';
    return itemAppointmentId == appointmentId;
  }).toList();
}

double transactionAmountForAppointment({
  required Map<String, dynamic> transaction,
  required String appointmentId,
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
  );
  if (appointmentItems.isEmpty) return 0;
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
