import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

const supportedServiceCategories = <String>[
  'Services',
  'Online',
  'Packages',
  'Add-ons',
];

class ServiceCategoryOrderController extends ValueNotifier<List<String>> {
  ServiceCategoryOrderController._()
    : super(List<String>.unmodifiable(supportedServiceCategories));

  static final instance = ServiceCategoryOrderController._();
  static const _storageKey = 'treats_service_category_order_v1';

  SharedPreferences? _storage;

  Future<void> initialize() async {
    final storage = await SharedPreferences.getInstance();
    _storage = storage;
    value = List<String>.unmodifiable(
      _normalizePreferredOrder(storage.getStringList(_storageKey)),
    );
  }

  List<String> orderAvailable(Iterable<String> categories) {
    final remaining = <String>{
      ...supportedServiceCategories,
      ...categories.map((category) => category.trim()),
    }..removeWhere((category) => category.isEmpty);
    final ordered = <String>[];

    for (final category in value) {
      if (remaining.remove(category)) ordered.add(category);
    }

    final additions = remaining.toList()
      ..sort((left, right) => left.toLowerCase().compareTo(right.toLowerCase()));
    return [...ordered, ...additions];
  }

  Future<void> saveOrder(Iterable<String> categories) async {
    final ordered = _normalizePreferredOrder(categories);
    value = List<String>.unmodifiable(ordered);
    final storage = _storage ?? await SharedPreferences.getInstance();
    _storage = storage;
    await storage.setStringList(_storageKey, ordered);
  }
}

List<String> _normalizePreferredOrder(Iterable<String>? categories) {
  final ordered = <String>[];

  for (final category in categories ?? const <String>[]) {
    final trimmed = category.trim();
    if (trimmed.isNotEmpty && !ordered.contains(trimmed)) {
      ordered.add(trimmed);
    }
  }

  if (ordered.isEmpty) {
    ordered.addAll(supportedServiceCategories);
  } else {
    for (final category in supportedServiceCategories) {
      if (!ordered.contains(category)) ordered.add(category);
    }
  }

  return ordered;
}
