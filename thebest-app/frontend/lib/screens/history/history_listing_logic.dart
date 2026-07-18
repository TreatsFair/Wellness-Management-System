enum SalesHistoryListing { bills, appointments }

DateTime _dateOnly(DateTime value) =>
    DateTime(value.year, value.month, value.day);

bool isScheduledHistoryAppointmentType(String type) {
  final normalized = type.trim().toLowerCase();
  return normalized.isEmpty ||
      normalized == 'appointment' ||
      normalized == 'online';
}

bool isHistoryVisitor({
  required DateTime? actualStartedAt,
  required DateTime selectedDate,
}) {
  return actualStartedAt != null &&
      _dateOnly(actualStartedAt) == _dateOnly(selectedDate);
}

double sumSettlementServiceNet<T>(
  Iterable<T> paidRecords,
  double Function(T record) serviceNet,
) => paidRecords.fold(0.0, (total, record) => total + serviceNet(record));

List<T> filterSalesHistoryListing<T>({
  required Iterable<T> records,
  required DateTime selectedDate,
  required SalesHistoryListing listing,
  required DateTime Function(T record) paidAt,
  required DateTime Function(T record) serviceAt,
}) {
  final selected = _dateOnly(selectedDate);
  final filtered = records.where((record) {
    final recordDate = listing == SalesHistoryListing.bills
        ? paidAt(record)
        : serviceAt(record);
    return _dateOnly(recordDate) == selected;
  }).toList();

  filtered.sort((left, right) {
    final leftDate = listing == SalesHistoryListing.bills
        ? paidAt(left)
        : serviceAt(left);
    final rightDate = listing == SalesHistoryListing.bills
        ? paidAt(right)
        : serviceAt(right);
    return rightDate.compareTo(leftDate);
  });
  return filtered;
}
