import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/screens/management/service_management_screen.dart';

void main() {
  ServiceCatalogueItem service({
    required String name,
    required String category,
    required bool active,
    required double price,
    required int duration,
    String description = '',
    String createdAt = '2026-07-01T00:00:00Z',
    int displayOrder = 0,
  }) {
    return ServiceCatalogueItem({
      'id': name,
      'name': name,
      'category': category,
      'isActive': active,
      'price': price,
      'duration': duration,
      'serviceDescription': description,
      'createdAt': createdAt,
      'displayOrder': displayOrder,
    });
  }

  final services = [
    service(
      name: 'Foot Massage',
      category: 'Services',
      active: true,
      price: 80,
      duration: 60,
      description: 'Relaxing foot treatment',
    ),
    service(
      name: 'Couple Package',
      category: 'Packages',
      active: true,
      price: 260,
      duration: 120,
      createdAt: '2026-07-10T00:00:00Z',
    ),
    service(
      name: 'Eye Mask',
      category: 'Add-ons',
      active: false,
      price: 15,
      duration: 15,
    ),
  ];

  test('filters by category and status', () {
    final result = filterAndSortServices(
      services: services,
      category: 'Add-ons',
      query: '',
      status: ServiceStatusFilter.inactive,
      sort: ServiceSort.name,
    );

    expect(result.map((item) => item.name), ['Eye Mask']);
  });

  test('search includes the service description', () {
    final result = filterAndSortServices(
      services: services,
      category: null,
      query: 'relaxing',
      status: ServiceStatusFilter.all,
      sort: ServiceSort.name,
    );

    expect(result.map((item) => item.name), ['Foot Massage']);
  });

  test('sorts by price and newest options', () {
    final byPrice = filterAndSortServices(
      services: services,
      category: null,
      query: '',
      status: ServiceStatusFilter.all,
      sort: ServiceSort.priceLow,
    );
    final newest = filterAndSortServices(
      services: services,
      category: null,
      query: '',
      status: ServiceStatusFilter.all,
      sort: ServiceSort.newest,
    );

    expect(byPrice.map((item) => item.name), [
      'Eye Mask',
      'Foot Massage',
      'Couple Package',
    ]);
    expect(newest.first.name, 'Couple Package');
  });

  test('manual ordering follows the shared display order', () {
    final ordered = [
      service(
        name: 'Third',
        category: 'Services',
        active: true,
        price: 30,
        duration: 30,
        displayOrder: 2,
      ),
      service(
        name: 'First',
        category: 'Services',
        active: true,
        price: 10,
        duration: 30,
        displayOrder: 0,
      ),
      service(
        name: 'Second',
        category: 'Services',
        active: true,
        price: 20,
        duration: 30,
        displayOrder: 1,
      ),
    ];

    final result = filterAndSortServices(
      services: ordered,
      category: 'Services',
      query: '',
      status: ServiceStatusFilter.all,
      sort: ServiceSort.manual,
    );

    expect(result.map((item) => item.name), ['First', 'Second', 'Third']);
  });
}
