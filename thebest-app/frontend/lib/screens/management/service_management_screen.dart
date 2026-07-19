import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../data/repositories/image_upload_repository.dart';
import '../../data/repositories/repository_utils.dart';
import '../../data/repositories/service_repository.dart';
import '../../data/services/supabase_table_service.dart';
import '../../widgets/adaptive_detail_surface.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/management_catalogue_shell.dart';

enum ServiceStatusFilter { all, active, inactive }

enum ServiceSort { manual, newest, name, priceLow, priceHigh, duration }

enum ServiceEditorResult { saved, deleted }

const _preferredServiceCategories = ['Services', 'Add-ons', 'Packages'];

int _compareServiceCategories(String left, String right) {
  final normalizedLeft = left.trim().toLowerCase();
  final normalizedRight = right.trim().toLowerCase();
  final leftPriority = _preferredServiceCategories.indexWhere(
    (category) => category.toLowerCase() == normalizedLeft,
  );
  final rightPriority = _preferredServiceCategories.indexWhere(
    (category) => category.toLowerCase() == normalizedRight,
  );
  if (leftPriority != -1 || rightPriority != -1) {
    if (leftPriority == -1) return 1;
    if (rightPriority == -1) return -1;
    return leftPriority.compareTo(rightPriority);
  }
  return normalizedLeft.compareTo(normalizedRight);
}

class ServiceManagementScreen extends StatefulWidget {
  const ServiceManagementScreen({super.key, this.userRole = 'staff'});

  final String userRole;

  @override
  State<ServiceManagementScreen> createState() =>
      _ServiceManagementScreenState();
}

class _ServiceManagementScreenState extends State<ServiceManagementScreen> {
  final _repository = ServiceRepository();
  final _categoryTable = SupabaseTableService('service_categories');
  final _searchController = TextEditingController();

  List<ServiceCatalogueItem> _services = const [];
  List<String> _categories = const [];
  Map<String, String> _categoryIdsByName = const {};
  bool _loading = true;
  String? _loadError;
  String? _selectedCategory;
  String? _selectedServiceId;
  ServiceStatusFilter _statusFilter = ServiceStatusFilter.all;
  final ServiceSort _sort = ServiceSort.manual;
  bool _gridView = true;
  bool _savingOrder = false;

  bool get _isAdmin => widget.userRole.trim().toLowerCase() == 'admin';

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_refreshView);
    _load();
  }

  @override
  void dispose() {
    _searchController
      ..removeListener(_refreshView)
      ..dispose();
    super.dispose();
  }

  void _refreshView() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _loadError = null;
      });
    }
    try {
      final rows = await _repository.getServices();
      List<Map<String, dynamic>> categoryRows = const [];
      try {
        categoryRows = await _categoryTable.list(orderBy: 'name');
      } catch (_) {
        // Categories can still be recovered from existing service records.
      }
      final services = rows.map(ServiceCatalogueItem.new).toList();
      final categories = <String>{
        ...categoryRows
            .where((row) => asBool(row['isActive'], true))
            .map((row) => asString(row['name']).trim()),
        ...services.map((service) => service.category),
      }..removeWhere((category) => category.isEmpty);
      if (!mounted) return;
      setState(() {
        _services = services;
        _categories = categories.toList()..sort(_compareServiceCategories);
        _categoryIdsByName = {
          for (final row in categoryRows)
            if (asString(row['name']).trim().isNotEmpty &&
                asString(row['id']).trim().isNotEmpty)
              asString(row['name']).trim(): asString(row['id']).trim(),
        };
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = error.toString();
      });
    }
  }

  void _openCatalogue([String? category]) {
    setState(() {
      _selectedCategory = category;
      _statusFilter = ServiceStatusFilter.all;
      _searchController.clear();
    });
  }

  List<ServiceCatalogueItem> get _visibleServices {
    return filterAndSortServices(
      services: _services,
      category: _selectedCategory,
      query: _searchController.text,
      status: _statusFilter,
      sort: _sort,
    );
  }

  bool get _canReorderVisibleServices =>
      _isAdmin &&
      _gridView &&
      _selectedCategory != null &&
      _statusFilter == ServiceStatusFilter.all &&
      _searchController.text.trim().isEmpty &&
      !_savingOrder;

  Future<void> _reorderService(String draggedId, String targetId) async {
    if (!_canReorderVisibleServices || draggedId == targetId) return;
    final ordered = [..._visibleServices];
    final fromIndex = ordered.indexWhere((item) => item.id == draggedId);
    final targetIndex = ordered.indexWhere((item) => item.id == targetId);
    if (fromIndex < 0 || targetIndex < 0) return;
    final moved = ordered.removeAt(fromIndex);
    ordered.insert(targetIndex, moved);
    final orderById = <String, int>{
      for (var index = 0; index < ordered.length; index++)
        ordered[index].id: index,
    };
    setState(() {
      _savingOrder = true;
      _services = _services
          .map(
            (service) => orderById.containsKey(service.id)
                ? ServiceCatalogueItem({
                    ...service.raw,
                    'displayOrder': orderById[service.id],
                  })
                : service,
          )
          .toList();
    });
    try {
      await _repository.updateServiceOrder(
        ordered.map((service) => service.id).toList(),
      );
      if (!mounted) return;
      setState(() => _savingOrder = false);
      AppToast.success(context, 'Service order saved for everyone');
    } catch (error) {
      if (!mounted) return;
      setState(() => _savingOrder = false);
      await _load();
      if (!mounted) return;
      AppToast.error(
        context,
        error.toString(),
        title: 'Unable to save service order',
      );
    }
  }

  Future<void> _openEditor([ServiceCatalogueItem? service]) async {
    setState(() => _selectedServiceId = service?.id);
    final result = await showAdaptiveDetailSurface<ServiceEditorResult>(
      context: context,
      barrierLabel: service == null ? 'Close new service' : 'Close service',
      builder: (context, isFullScreen) => ServiceEditorSurface(
        service: service,
        categories: _categories,
        initialCategory: _selectedCategory ?? 'Services',
        isAdmin: _isAdmin,
        isFullScreen: isFullScreen,
      ),
    );
    if (!mounted) return;
    setState(() => _selectedServiceId = null);
    if (result == null) return;
    await _load();
    if (!mounted) return;
    if (result == ServiceEditorResult.deleted) {
      AppToast.success(context, 'Service deleted');
    } else {
      AppToast.success(
        context,
        service == null ? 'Service added' : 'Changes saved',
      );
    }
  }

  Future<void> _openServiceDetails(ServiceCatalogueItem service) async {
    setState(() => _selectedServiceId = service.id);
    final editRequested = await showAdaptiveDetailSurface<bool>(
      context: context,
      barrierLabel: 'Close service details',
      builder: (detailContext, isFullScreen) =>
          ManagementCatalogueDetailSurface(
            title: 'Service Details',
            subtitle: service.name,
            isFullScreen: isFullScreen,
            footer: CatalogueDetailEditButton(
              label: 'Edit Service',
              onPressed: () => Navigator.of(detailContext).pop(true),
            ),
            child: _ServiceReadOnlyDetails(service: service),
          ),
    );
    if (!mounted) return;
    setState(() => _selectedServiceId = null);
    if (editRequested == true) await _openEditor(service);
  }

  Future<void> _addCategory() async {
    if (!_isAdmin) {
      AppToast.error(context, 'Only an admin can add service categories.');
      return;
    }
    final category = await showAdaptiveDetailSurface<String>(
      context: context,
      barrierLabel: 'Close new category',
      builder: (context, isFullScreen) =>
          _CategoryEditorSurface(isFullScreen: isFullScreen),
    );
    final normalizedName = category?.trim() ?? '';
    if (normalizedName.isEmpty || !mounted) return;
    final existing = _categories.where(
      (item) => item.toLowerCase() == normalizedName.toLowerCase(),
    );
    if (existing.isNotEmpty) {
      _openCatalogue(existing.first);
      return;
    }
    final code = normalizedName
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    try {
      await _categoryTable.create({
        'code': code,
        'name': normalizedName,
        'isActive': true,
      });
      await _load();
      if (!mounted) return;
      _openCatalogue(normalizedName);
      AppToast.success(context, 'Category added');
    } catch (error) {
      if (!mounted) return;
      AppToast.error(
        context,
        error.toString(),
        title: 'Unable to add category',
      );
    }
  }

  Future<bool> _confirmDeleteEmptyCategory(
    String category,
    String categoryId,
  ) async {
    if (!_isAdmin || _services.any((service) => service.category == category)) {
      return false;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.delete_outline, color: AppColors.danger),
        title: const Text('Delete empty category?'),
        content: Text(
          '$category has no services. Deleting it removes the category from Services, Walk-in, and Appointments.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            child: const Text('Delete Category'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return false;
    try {
      // Re-read from the source of truth immediately before deletion. The
      // catalogue may have gained a service while the confirmation was open.
      final latestServices = await _repository.getServices();
      final isStillEmpty = !latestServices.any(
        (service) =>
            asString(service['category']).trim().toLowerCase() ==
            category.trim().toLowerCase(),
      );
      if (!isStillEmpty) {
        if (!mounted) return false;
        await _load();
        if (!mounted) return false;
        AppToast.error(
          context,
          '$category now contains services and cannot be deleted.',
          title: 'Category is not empty',
        );
        return false;
      }
      await _categoryTable.delete(categoryId);
      if (!mounted) return false;
      setState(() {
        _categories = _categories.where((item) => item != category).toList();
        _categoryIdsByName = Map<String, String>.from(_categoryIdsByName)
          ..remove(category);
        if (_selectedCategory == category) _selectedCategory = null;
      });
      AppToast.success(context, 'Category deleted');
      return true;
    } catch (error) {
      if (!mounted) return false;
      AppToast.error(
        context,
        error.toString(),
        title: 'Unable to delete category',
      );
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_loadError != null) {
      return Scaffold(
        backgroundColor: context.appCanvas,
        body: _LoadFailure(message: _loadError!, onRetry: _load),
      );
    }
    return _buildSplitView();
  }

  Widget _buildSplitView() {
    final visible = _visibleServices;
    final categoryTitle = _selectedCategory ?? 'All Services';
    return ManagementCatalogueShell(
      moduleTitle: 'Services',
      moduleSubtitle: 'Manage services and pricing',
      contentTitle: categoryTitle,
      itemCountLabel:
          '${visible.length} service${visible.length == 1 ? '' : 's'}${_isAdmin && _selectedCategory != null ? ' · Hold a card to reorder' : ''}',
      addLabel: 'Add Service',
      onAdd: () => _openEditor(),
      navigation: _buildCategorySidebar(),
      mobileNavigation: _buildHub(),
      headerActions: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 190,
            child: CatalogueSearchField(
              controller: _searchController,
              hintText: 'Search services...',
            ),
          ),
          const SizedBox(width: 8),
          _StatusMenu(
            value: _statusFilter,
            onChanged: (value) => setState(() => _statusFilter = value),
          ),
          const SizedBox(width: 8),
          CatalogueViewSwitch(
            gridView: _gridView,
            onChanged: (value) => setState(() => _gridView = value),
          ),
        ],
      ),
      content: _buildCatalogue(),
    );
  }

  Widget _buildCategorySidebar() {
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(14, 18, 14, 12),
            children: [
              CatalogueSidebarTile(
                title: 'All Services',
                subtitle: 'Complete service catalogue',
                count: _services.length,
                icon: Icons.spa_outlined,
                color: AppColors.primary,
                selected: _selectedCategory == null,
                onTap: () => _openCatalogue(),
              ),
              ..._categories.map((category) {
                final count = _services
                    .where((service) => service.category == category)
                    .length;
                final tile = CatalogueSidebarTile(
                  title: category,
                  subtitle: _categorySubtitle(category),
                  count: count,
                  icon: _categoryIcon(category),
                  color: _categoryColor(category),
                  selected: _selectedCategory == category,
                  onTap: () => _openCatalogue(category),
                );
                final categoryId = _categoryIdsByName[category];
                if (!_isAdmin || count != 0 || categoryId == null) return tile;
                return Dismissible(
                  key: ValueKey('service-category-$categoryId'),
                  direction: DismissDirection.endToStart,
                  confirmDismiss: (_) =>
                      _confirmDeleteEmptyCategory(category, categoryId),
                  background: Container(
                    margin: const EdgeInsets.only(bottom: 6),
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    alignment: Alignment.centerRight,
                    decoration: BoxDecoration(
                      color: AppColors.danger,
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Icon(Icons.delete_outline, color: Colors.white),
                        SizedBox(width: 7),
                        Text(
                          'Delete',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                  ),
                  child: tile,
                );
              }),
            ],
          ),
        ),
        if (_isAdmin)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 16),
            decoration: BoxDecoration(
              color: context.appSurface,
              border: Border(top: BorderSide(color: context.appBorder)),
            ),
            child: OutlinedButton.icon(
              onPressed: _addCategory,
              icon: const Icon(Icons.create_new_folder_outlined, size: 18),
              label: const Text('Add Category'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(44),
                foregroundColor: context.appColors.primary,
                side: BorderSide(color: context.appColors.primary),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildHub() {
    return CatalogueMobileNavigation(
      children: [
        CatalogueNavigationChip(
          label: 'All Services (${_services.length})',
          selected: _selectedCategory == null,
          onTap: () => _openCatalogue(),
        ),
        ..._categories.map((category) {
          final count = _services
              .where((service) => service.category == category)
              .length;
          return CatalogueNavigationChip(
            label: '$category ($count)',
            selected: _selectedCategory == category,
            onTap: () => _openCatalogue(category),
          );
        }),
      ],
    );
  }

  Widget _buildCatalogue() {
    final visible = _visibleServices;
    return RefreshIndicator(
      key: const ValueKey('service-catalogue'),
      onRefresh: _load,
      child: visible.isEmpty
          ? _EmptyCatalogue(
              hasFilters:
                  _searchController.text.trim().isNotEmpty ||
                  _statusFilter != ServiceStatusFilter.all,
            )
          : LayoutBuilder(
              builder: (context, constraints) {
                final padding = constraints.maxWidth >= 900 ? 24.0 : 16.0;
                final cardHeight =
                    context.managementCatalogueCardHeight +
                    (constraints.maxWidth < 600 ? 16 : 0);
                if (!_gridView) {
                  return ListView.separated(
                    padding: EdgeInsets.fromLTRB(padding, 16, padding, 28),
                    itemCount: visible.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (context, index) {
                      final service = visible[index];
                      return _ServiceListTile(
                        service: service,
                        selected: service.id == _selectedServiceId,
                        onTap: () => _openServiceDetails(service),
                      );
                    },
                  );
                }
                return GridView.builder(
                  padding: EdgeInsets.fromLTRB(padding, 16, padding, 28),
                  gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 330,
                    mainAxisExtent: cardHeight,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                  ),
                  itemCount: visible.length,
                  itemBuilder: (context, index) {
                    final service = visible[index];
                    final card = _ServiceCard(
                      service: service,
                      selected: service.id == _selectedServiceId,
                      onTap: () => _openServiceDetails(service),
                    );
                    if (!_canReorderVisibleServices) return card;
                    return _ReorderableServiceCard(
                      serviceId: service.id,
                      cardHeight: cardHeight,
                      onMove: _reorderService,
                      child: card,
                    );
                  },
                );
              },
            ),
    );
  }
}

class _CategoryEditorSurface extends StatefulWidget {
  const _CategoryEditorSurface({required this.isFullScreen});

  final bool isFullScreen;

  @override
  State<_CategoryEditorSurface> createState() => _CategoryEditorSurfaceState();
}

class _CategoryEditorSurfaceState extends State<_CategoryEditorSurface> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.of(context).pop(_name.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: context.appSurface,
      child: SafeArea(
        top: widget.isFullScreen,
        bottom: widget.isFullScreen,
        child: Column(
          children: [
            Container(
              constraints: const BoxConstraints(minHeight: 66),
              padding: EdgeInsets.fromLTRB(
                widget.isFullScreen ? 4 : 18,
                10,
                8,
                10,
              ),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: context.appBorder)),
              ),
              child: Row(
                children: [
                  if (widget.isFullScreen) ...[
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      tooltip: 'Back',
                      icon: const Icon(Icons.arrow_back_rounded),
                    ),
                    const SizedBox(width: 2),
                  ],
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Add Category',
                          style: TextStyle(
                            color: context.appText,
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        Text(
                          'Create a category for service selection',
                          style: TextStyle(
                            color: context.appMuted,
                            fontSize: 11.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (!widget.isFullScreen)
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      tooltip: 'Close',
                      icon: const Icon(Icons.close_rounded),
                    ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(18),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Category information',
                        style: TextStyle(
                          color: Color(0xFF344054),
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _name,
                        autofocus: true,
                        textCapitalization: TextCapitalization.words,
                        decoration: const InputDecoration(
                          labelText: 'Category name *',
                          hintText: 'Example: Wellness Programs',
                          helperText:
                              'This will appear in Services, Walk-in, and Appointments.',
                        ),
                        onFieldSubmitted: (_) => _submit(),
                        validator: (value) =>
                            value == null || value.trim().isEmpty
                            ? 'Enter a category name'
                            : null,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: context.appBorder)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(44),
                      ),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      onPressed: _submit,
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(44),
                        backgroundColor: context.appColors.primary,
                      ),
                      child: const Text('Add Category'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ServiceCatalogueItem {
  ServiceCatalogueItem(this.raw);

  final Map<String, dynamic> raw;

  String get id => asString(raw['id']);
  String get name => asString(raw['name'], 'Unnamed service').trim();
  String get category => asString(raw['category'], 'Services').trim();
  String get description =>
      asString(raw['serviceDescription'] ?? raw['service_description']).trim();
  String get imageUrl => asString(raw['imageUrl'] ?? raw['image_url']).trim();
  int get duration => asInt(raw['duration'], 60);
  int get bufferAfterMinutes =>
      asInt(raw['bufferAfterMinutes'] ?? raw['buffer_after_minutes']);
  double get price => asDouble(raw['price']);
  double get therapistCommission =>
      asDouble(raw['therapistCommission'] ?? raw['therapist_commission']);
  double get counterCommission =>
      asDouble(raw['counterCommission'] ?? raw['counter_commission']);
  String get roomType =>
      asString(raw['roomType'] ?? raw['room_type'], 'body_room');
  bool get active => asBool(raw['isActive'] ?? raw['is_active'], true);
  DateTime get createdAt =>
      DateTime.tryParse(asString(raw['createdAt'] ?? raw['created_at'])) ??
      DateTime.fromMillisecondsSinceEpoch(0);
  int get displayOrder => asInt(raw['displayOrder']);
}

List<ServiceCatalogueItem> filterAndSortServices({
  required List<ServiceCatalogueItem> services,
  required String? category,
  required String query,
  required ServiceStatusFilter status,
  required ServiceSort sort,
}) {
  final normalizedQuery = query.trim().toLowerCase();
  final filtered = services.where((service) {
    final inCategory = category == null || service.category == category;
    final inStatus = switch (status) {
      ServiceStatusFilter.all => true,
      ServiceStatusFilter.active => service.active,
      ServiceStatusFilter.inactive => !service.active,
    };
    final matchesQuery =
        normalizedQuery.isEmpty ||
        service.name.toLowerCase().contains(normalizedQuery) ||
        service.category.toLowerCase().contains(normalizedQuery) ||
        service.description.toLowerCase().contains(normalizedQuery);
    return inCategory && inStatus && matchesQuery;
  }).toList();

  filtered.sort(
    (a, b) => switch (sort) {
      ServiceSort.manual =>
        a.displayOrder != b.displayOrder
            ? a.displayOrder.compareTo(b.displayOrder)
            : a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      ServiceSort.newest => b.createdAt.compareTo(a.createdAt),
      ServiceSort.name => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      ServiceSort.priceLow => a.price.compareTo(b.price),
      ServiceSort.priceHigh => b.price.compareTo(a.price),
      ServiceSort.duration => a.duration.compareTo(b.duration),
    },
  );
  return filtered;
}

class _StatusMenu extends StatelessWidget {
  const _StatusMenu({required this.value, required this.onChanged});

  final ServiceStatusFilter value;
  final ValueChanged<ServiceStatusFilter> onChanged;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<ServiceStatusFilter>(
      initialValue: value,
      onSelected: onChanged,
      tooltip: 'Filter by status',
      itemBuilder: (_) => const [
        PopupMenuItem(
          value: ServiceStatusFilter.all,
          child: Text('All statuses'),
        ),
        PopupMenuItem(value: ServiceStatusFilter.active, child: Text('Active')),
        PopupMenuItem(
          value: ServiceStatusFilter.inactive,
          child: Text('Inactive'),
        ),
      ],
      child: CatalogueToolbarButton(
        icon: Icons.filter_list,
        label: switch (value) {
          ServiceStatusFilter.all => 'All',
          ServiceStatusFilter.active => 'Active',
          ServiceStatusFilter.inactive => 'Inactive',
        },
      ),
    );
  }
}

class _ServiceReadOnlyDetails extends StatelessWidget {
  const _ServiceReadOnlyDetails({required this.service});

  final ServiceCatalogueItem service;

  @override
  Widget build(BuildContext context) {
    final roomLabel = service.roomType
        .replaceAll('_', ' ')
        .split(' ')
        .where((part) => part.isNotEmpty)
        .map((part) => '${part[0].toUpperCase()}${part.substring(1)}')
        .join(' ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: context.appSurface,
            borderRadius: BorderRadius.circular(AppRadius.card),
            border: Border.all(color: context.appBorder),
          ),
          child: Row(
            children: [
              _ServiceAvatar(service: service, size: 58),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      service.name,
                      style: TextStyle(
                        color: context.appText,
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 6),
                    _CategoryBadge(category: service.category),
                  ],
                ),
              ),
              _StatusBadge(active: service.active),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _ServiceReadOnlySection(
          title: 'Basic information',
          children: [
            _ServiceDetailRow(label: 'Category', value: service.category),
            _ServiceDetailRow(
              label: 'Description',
              value: service.description.isEmpty
                  ? 'No description added'
                  : service.description,
              last: true,
            ),
          ],
        ),
        const SizedBox(height: 12),
        _ServiceReadOnlySection(
          title: 'Pricing and duration',
          children: [
            _ServiceDetailRow(
              label: 'Duration',
              value: '${service.duration} minutes',
            ),
            _ServiceDetailRow(
              label: 'Price',
              value: 'RM ${service.price.toStringAsFixed(2)}',
            ),
            _ServiceDetailRow(
              label: 'Cleanup buffer',
              value: '${service.bufferAfterMinutes} minutes',
              last: true,
            ),
          ],
        ),
        const SizedBox(height: 12),
        _ServiceReadOnlySection(
          title: 'Commission and room',
          children: [
            _ServiceDetailRow(
              label: 'Therapist commission',
              value: 'RM ${service.therapistCommission.toStringAsFixed(2)}',
            ),
            _ServiceDetailRow(
              label: 'Counter commission',
              value: 'RM ${service.counterCommission.toStringAsFixed(2)}',
            ),
            _ServiceDetailRow(label: 'Room type', value: roomLabel, last: true),
          ],
        ),
      ],
    );
  }
}

class _ServiceReadOnlySection extends StatelessWidget {
  const _ServiceReadOnlySection({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: context.appSurface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: context.appBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              color: context.appText,
              fontSize: 13,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 10),
          ...children,
        ],
      ),
    );
  }
}

class _ServiceDetailRow extends StatelessWidget {
  const _ServiceDetailRow({
    required this.label,
    required this.value,
    this.last = false,
  });

  final String label;
  final String value;
  final bool last;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 9),
      decoration: BoxDecoration(
        border: last
            ? null
            : Border(bottom: BorderSide(color: context.appBorder)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 132,
            child: Text(
              label,
              style: TextStyle(color: context.appMuted, fontSize: 12),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: TextStyle(
                color: context.appText,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ReorderableServiceCard extends StatelessWidget {
  const _ReorderableServiceCard({
    required this.serviceId,
    required this.cardHeight,
    required this.onMove,
    required this.child,
  });

  final String serviceId;
  final double cardHeight;
  final Future<void> Function(String draggedId, String targetId) onMove;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DragTarget<String>(
      onWillAcceptWithDetails: (details) => details.data != serviceId,
      onAcceptWithDetails: (details) => onMove(details.data, serviceId),
      builder: (context, candidates, rejected) => AnimatedScale(
        scale: candidates.isEmpty ? 1 : 1.025,
        duration: const Duration(milliseconds: 120),
        child: LongPressDraggable<String>(
          data: serviceId,
          delay: const Duration(milliseconds: 420),
          feedback: Material(
            color: Colors.transparent,
            elevation: 10,
            borderRadius: BorderRadius.circular(AppRadius.card),
            child: SizedBox(
              width: 300,
              height: cardHeight,
              child: IgnorePointer(child: child),
            ),
          ),
          childWhenDragging: Opacity(opacity: 0.3, child: child),
          child: Tooltip(message: 'Hold and drag to reorder', child: child),
        ),
      ),
    );
  }
}

class _ServiceCard extends StatelessWidget {
  const _ServiceCard({
    required this.service,
    required this.selected,
    required this.onTap,
  });

  final ServiceCatalogueItem service;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final narrowGrid = MediaQuery.sizeOf(context).width < 600;
    return Material(
      color: selected ? AppColors.primarySoft : context.appSurface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
        side: BorderSide(
          color: selected ? context.appColors.primary : context.appBorder,
          width: selected ? 1.5 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.all(narrowGrid ? 12 : 15),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _ServiceAvatar(service: service, size: narrowGrid ? 40 : 46),
                  SizedBox(width: narrowGrid ? 8 : 11),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          service.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: context.appText,
                            fontWeight: FontWeight.w800,
                            height: 1.2,
                          ),
                        ),
                        const SizedBox(height: 6),
                        _CategoryBadge(category: service.category),
                      ],
                    ),
                  ),
                  Icon(
                    Icons.chevron_right,
                    size: narrowGrid ? 18 : 20,
                    color: context.appMuted,
                  ),
                ],
              ),
              const Spacer(),
              Text(
                service.bufferAfterMinutes > 0
                    ? '${service.duration} min + ${service.bufferAfterMinutes} min cleanup'
                    : '${service.duration} min',
                style: TextStyle(color: context.appMuted, fontSize: 12),
              ),
              const SizedBox(height: 5),
              Text(
                'RM ${service.price.toStringAsFixed(2)}',
                style: TextStyle(
                  color: context.appText,
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                'Commission RM ${service.therapistCommission.toStringAsFixed(0)} / ${service.counterCommission.toStringAsFixed(0)}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: context.appMuted, fontSize: 11.5),
              ),
              SizedBox(height: narrowGrid ? 8 : 12),
              Align(
                alignment: Alignment.centerRight,
                child: _StatusBadge(active: service.active),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ServiceListTile extends StatelessWidget {
  const _ServiceListTile({
    required this.service,
    required this.selected,
    required this.onTap,
  });

  final ServiceCatalogueItem service;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? AppColors.primarySoft : context.appSurface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
        side: BorderSide(
          color: selected ? context.appColors.primary : context.appBorder,
        ),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.card),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              _ServiceAvatar(service: service, size: 48),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      service.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: context.appText,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 5,
                      children: [
                        _CategoryBadge(category: service.category),
                        _StatusBadge(active: service.active),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${service.duration} min · RM ${service.price.toStringAsFixed(2)} · Commission RM ${service.therapistCommission.toStringAsFixed(0)}/${service.counterCommission.toStringAsFixed(0)}',
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: context.appMuted, fontSize: 12),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              Icon(Icons.chevron_right, color: context.appMuted),
            ],
          ),
        ),
      ),
    );
  }
}

class _ServiceAvatar extends StatelessWidget {
  const _ServiceAvatar({
    required this.service,
    required this.size,
    this.preview,
    this.imageRemoved = false,
  });

  final ServiceCatalogueItem service;
  final double size;
  final SelectedImage? preview;
  final bool imageRemoved;

  @override
  Widget build(BuildContext context) {
    final url = imageRemoved ? '' : service.imageUrl;
    final fallback = Container(
      width: size,
      height: size,
      color: _avatarColor(service.name),
      alignment: Alignment.center,
      child: Text(
        _initials(service.name),
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
    return ClipOval(
      child: SizedBox(
        width: size,
        height: size,
        child: preview != null
            ? Image.memory(preview!.bytes, fit: BoxFit.cover)
            : url.isNotEmpty
            ? CachedNetworkImage(
                imageUrl: url,
                fit: BoxFit.cover,
                placeholder: (_, _) => fallback,
                errorWidget: (_, _, _) => fallback,
              )
            : fallback,
      ),
    );
  }
}

class _CategoryBadge extends StatelessWidget {
  const _CategoryBadge({required this.category});

  final String category;

  @override
  Widget build(BuildContext context) {
    final color = _categoryColor(category);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 190),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.11),
          borderRadius: BorderRadius.circular(AppRadius.pill),
        ),
        child: Text(
          category,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: color,
            fontSize: 10.5,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.active});

  final bool active;

  @override
  Widget build(BuildContext context) {
    final color = active ? AppColors.success : context.appMuted;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 5),
        Text(
          active ? 'Active' : 'Inactive',
          style: TextStyle(
            color: color,
            fontSize: 11,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    );
  }
}

class _EmptyCatalogue extends StatelessWidget {
  const _EmptyCatalogue({required this.hasFilters});

  final bool hasFilters;

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        SizedBox(height: MediaQuery.sizeOf(context).height * 0.18),
        Icon(Icons.spa_outlined, size: 46, color: context.appMuted),
        const SizedBox(height: 12),
        Text(
          hasFilters ? 'No matching services' : 'No services in this group yet',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: context.appText,
            fontSize: 16,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 5),
        Text(
          hasFilters
              ? 'Try changing the search or status filter.'
              : 'Use Add Service above when you are ready to create one.',
          textAlign: TextAlign.center,
          style: TextStyle(color: context.appMuted),
        ),
      ],
    );
  }
}

class _LoadFailure extends StatelessWidget {
  const _LoadFailure({required this.message, required this.onRetry});

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_outlined, size: 42),
            const SizedBox(height: 12),
            const Text(
              'Unable to load services',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: context.appMuted),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Try Again'),
            ),
          ],
        ),
      ),
    );
  }
}

String _categorySubtitle(String category) {
  final value = category.toLowerCase();
  if (value.contains('package')) return 'Bundled treatments and offers';
  if (value.contains('add')) return 'Optional add-on treatments';
  return 'Browse $category';
}

IconData _categoryIcon(String category) {
  final value = category.toLowerCase();
  if (value.contains('package')) return Icons.card_giftcard_outlined;
  if (value.contains('add')) return Icons.add_circle_outline;
  if (value.contains('massage')) return Icons.self_improvement_outlined;
  return Icons.content_cut;
}

Color _categoryColor(String category) {
  final value = category.toLowerCase();
  if (value.contains('package')) return const Color(0xFF7C3AED);
  if (value.contains('add')) return const Color(0xFFD97706);
  if (value.contains('massage')) return const Color(0xFF2563EB);
  return AppColors.primary;
}

Color _avatarColor(String seed) {
  const colors = [
    AppColors.primary,
    Color(0xFF2563EB),
    Color(0xFF7C3AED),
    Color(0xFFD97706),
    Color(0xFFBE185D),
  ];
  final sum = seed.codeUnits.fold<int>(0, (total, value) => total + value);
  return colors[sum % colors.length];
}

String _initials(String name) {
  final parts = name
      .trim()
      .split(RegExp(r'\s+'))
      .where((part) => part.isNotEmpty)
      .toList();
  if (parts.isEmpty) return '?';
  if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
  return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
}

class ServiceEditorSurface extends StatefulWidget {
  const ServiceEditorSurface({
    super.key,
    required this.categories,
    required this.initialCategory,
    required this.isAdmin,
    required this.isFullScreen,
    this.service,
  });

  final ServiceCatalogueItem? service;
  final List<String> categories;
  final String initialCategory;
  final bool isAdmin;
  final bool isFullScreen;

  @override
  State<ServiceEditorSurface> createState() => _ServiceEditorSurfaceState();
}

class _ServiceEditorSurfaceState extends State<ServiceEditorSurface> {
  final _formKey = GlobalKey<FormState>();
  final _repository = ServiceRepository();
  final _imageRepository = ImageUploadRepository();
  final _categoryTable = SupabaseTableService('service_categories');

  late final TextEditingController _name;
  late final TextEditingController _description;
  late final TextEditingController _duration;
  late final TextEditingController _price;
  late final TextEditingController _bufferAfter;
  late final TextEditingController _therapistCommission;
  late final TextEditingController _counterCommission;
  late List<String> _categories;
  late String _category;
  late String _roomType;
  late bool _active;
  SelectedImage? _imagePreview;
  bool _imageRemoved = false;
  bool _dirty = false;
  bool _saving = false;
  int _tab = 0;

  bool get _editing => widget.service != null;

  @override
  void initState() {
    super.initState();
    final service = widget.service;
    _name = TextEditingController(text: service?.name ?? '');
    _description = TextEditingController(text: service?.description ?? '');
    _duration = TextEditingController(text: '${service?.duration ?? 60}');
    _price = TextEditingController(
      text: (service?.price ?? 0).toStringAsFixed(2),
    );
    _bufferAfter = TextEditingController(
      text: '${service?.bufferAfterMinutes ?? 0}',
    );
    _therapistCommission = TextEditingController(
      text: (service?.therapistCommission ?? 0).toStringAsFixed(2),
    );
    _counterCommission = TextEditingController(
      text: (service?.counterCommission ?? 0).toStringAsFixed(2),
    );
    _categories =
        <String>{
            ..._preferredServiceCategories,
            ...widget.categories,
            service?.category ?? widget.initialCategory,
          }.where((item) => item.trim().isNotEmpty).toList()
          ..sort(_compareServiceCategories);
    _category = service?.category ?? widget.initialCategory;
    if (!_categories.contains(_category)) _categories.add(_category);
    _roomType = _normalizeRoomType(service?.roomType ?? 'body_room');
    _active = service?.active ?? true;
    for (final controller in [
      _name,
      _description,
      _duration,
      _price,
      _bufferAfter,
      _therapistCommission,
      _counterCommission,
    ]) {
      controller.addListener(_markDirty);
    }
  }

  @override
  void dispose() {
    for (final controller in [
      _name,
      _description,
      _duration,
      _price,
      _bufferAfter,
      _therapistCommission,
      _counterCommission,
    ]) {
      controller
        ..removeListener(_markDirty)
        ..dispose();
    }
    super.dispose();
  }

  void _markDirty() {
    if (!_dirty && mounted) setState(() => _dirty = true);
  }

  void _setDirty(VoidCallback update) {
    setState(() {
      update();
      _dirty = true;
    });
  }

  Future<void> _requestClose() async {
    if (_saving) return;
    if (_dirty) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Discard unsaved changes?'),
          content: const Text(
            'The changes made to this service have not been saved.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Keep Editing'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
              child: const Text('Discard'),
            ),
          ],
        ),
      );
      if (discard != true || !mounted) return;
    }
    setState(() => _dirty = false);
    await Future<void>.delayed(Duration.zero);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _tab = 0);
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);

    final data = <String, dynamic>{
      'name': _name.text.trim(),
      'serviceDescription': _description.text.trim(),
      'category': _category,
      'duration': int.parse(_duration.text.trim()),
      'price': double.parse(_price.text.trim()),
      'bufferAfterMinutes': int.parse(_bufferAfter.text.trim()),
      'roomType': _roomType,
      'isActive': _active,
      if (widget.isAdmin) ...{
        'therapistCommission': double.parse(_therapistCommission.text.trim()),
        'counterCommission': double.parse(_counterCommission.text.trim()),
        if (_imageRemoved) 'imageUrl': '',
      },
    };

    try {
      final saved = _editing
          ? await _repository.updateService(widget.service!.id, data)
          : await _repository.addService(data);
      final serviceId = asString(saved['id'], widget.service?.id ?? '');
      if (widget.isAdmin && serviceId.isNotEmpty) {
        final previousUrl = widget.service?.imageUrl ?? '';
        if (_imagePreview != null) {
          final url = await _imageRepository.uploadImage(
            image: _imagePreview!,
            folder: 'services',
            id: serviceId,
            previousUrl: previousUrl,
          );
          await _repository.updateService(serviceId, {'imageUrl': url});
        } else if (_imageRemoved && previousUrl.isNotEmpty) {
          await _imageRepository.removePublicUrl(previousUrl);
        }
      }
      if (!mounted) return;
      _dirty = false;
      Navigator.of(context).pop(ServiceEditorResult.saved);
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      AppToast.error(
        context,
        error.toString(),
        title: 'Unable to save service',
      );
    }
  }

  Future<void> _delete() async {
    if (!_editing || !widget.isAdmin || _saving) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.delete_outline, color: AppColors.danger),
        title: const Text('Delete this service?'),
        content: Text(
          '${widget.service!.name} will be permanently removed. If it is used by historical appointments or receipts, deletion may be blocked. Inactive is safer for services you no longer sell.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            child: const Text('Delete Service'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _saving = true);
    try {
      await _repository.deleteService(widget.service!.id);
      if (!mounted) return;
      _dirty = false;
      Navigator.of(context).pop(ServiceEditorResult.deleted);
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      AppToast.error(
        context,
        'This service may be linked to existing records. Set it to Inactive instead.\n$error',
        title: 'Unable to delete service',
      );
    }
  }

  Future<void> _pickImage() async {
    if (!widget.isAdmin || _saving) return;
    try {
      final image = await _imageRepository.pickImage();
      if (image == null || !mounted) return;
      _setDirty(() {
        _imagePreview = image;
        _imageRemoved = false;
      });
    } catch (error) {
      if (mounted) AppToast.error(context, error.toString());
    }
  }

  Future<void> _addCategory() async {
    if (!widget.isAdmin || _saving) return;
    final controller = TextEditingController();
    final category = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Add service category'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            labelText: 'Category name',
            hintText: 'Example: Wellness Programs',
          ),
          onSubmitted: (value) {
            if (value.trim().isNotEmpty) {
              Navigator.pop(dialogContext, value.trim());
            }
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (controller.text.trim().isNotEmpty) {
                Navigator.pop(dialogContext, controller.text.trim());
              }
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (category == null || category.isEmpty || !mounted) return;

    final match = _categories.where(
      (item) => item.toLowerCase() == category.toLowerCase(),
    );
    if (match.isNotEmpty) {
      _setDirty(() => _category = match.first);
      return;
    }

    final code = category
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    try {
      await _categoryTable.create({
        'code': code,
        'name': category,
        'isActive': true,
      });
      if (!mounted) return;
      _setDirty(() {
        _categories = [..._categories, category]
          ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
        _category = category;
      });
    } catch (error) {
      if (mounted) {
        AppToast.error(
          context,
          error.toString(),
          title: 'Unable to add category',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final previewService = ServiceCatalogueItem({
      ...?widget.service?.raw,
      'name': _name.text.trim().isEmpty ? 'New Service' : _name.text.trim(),
      'imageUrl': widget.service?.imageUrl ?? '',
    });
    return PopScope(
      canPop: !_dirty || _saving,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _requestClose();
      },
      child: Material(
        color: context.appSurface,
        child: SafeArea(
          top: widget.isFullScreen,
          bottom: widget.isFullScreen,
          child: Column(
            children: [
              _EditorHeader(
                editing: _editing,
                active: _active,
                saving: _saving,
                isFullScreen: widget.isFullScreen,
                service: previewService,
                preview: _imagePreview,
                imageRemoved: _imageRemoved,
                onActiveChanged: (value) => _setDirty(() => _active = value),
                onClose: _requestClose,
              ),
              _EditorTabs(
                selected: _tab,
                onChanged: (value) => setState(() => _tab = value),
              ),
              Expanded(
                child: Form(
                  key: _formKey,
                  child: IndexedStack(
                    index: _tab,
                    children: [_buildDetails(), _buildMedia(previewService)],
                  ),
                ),
              ),
              _EditorFooter(
                saving: _saving,
                editing: _editing,
                onCancel: _requestClose,
                onSave: _save,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDetails() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionTitle('Basic information'),
          const SizedBox(height: 12),
          TextFormField(
            controller: _name,
            enabled: !_saving,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: 'Service name *'),
            validator: (value) => value == null || value.trim().isEmpty
                ? 'Enter a service name'
                : null,
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _category,
            decoration: const InputDecoration(labelText: 'Category *'),
            items: _categories
                .map(
                  (category) =>
                      DropdownMenuItem(value: category, child: Text(category)),
                )
                .toList(),
            onChanged: _saving
                ? null
                : (value) {
                    if (value != null) _setDirty(() => _category = value);
                  },
          ),
          if (widget.isAdmin)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: _saving ? null : _addCategory,
                icon: const Icon(Icons.add, size: 17),
                label: const Text('Add category'),
              ),
            ),
          const SizedBox(height: 4),
          TextFormField(
            controller: _description,
            enabled: !_saving,
            maxLines: 4,
            maxLength: 300,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Description',
              alignLabelWithHint: true,
              hintText: 'Briefly describe what this service includes',
            ),
          ),
          const SizedBox(height: 8),
          const _SectionTitle('Pricing and duration'),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextFormField(
                  controller: _duration,
                  enabled: !_saving,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Duration *',
                    suffixText: 'min',
                  ),
                  validator: (value) =>
                      _positiveIntError(value, 'Enter a valid duration'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextFormField(
                  controller: _price,
                  enabled: !_saving,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Price *',
                    prefixText: 'RM ',
                  ),
                  validator: (value) =>
                      _nonNegativeNumberError(value, 'Enter a valid price'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _bufferAfter,
            enabled: !_saving,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Cleanup buffer',
              suffixText: 'min',
              helperText: 'Reserved after treatment for room preparation',
            ),
            validator: (value) {
              final parsed = int.tryParse(value?.trim() ?? '');
              if (parsed == null || parsed < 0 || parsed > 240) {
                return 'Use a value from 0 to 240';
              }
              return null;
            },
          ),
          const SizedBox(height: 20),
          const _SectionTitle('Commission'),
          const SizedBox(height: 4),
          if (!widget.isAdmin)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(
                'Commission values can only be changed by an admin.',
                style: TextStyle(color: context.appMuted, fontSize: 12),
              ),
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextFormField(
                  controller: _therapistCommission,
                  enabled: widget.isAdmin && !_saving,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Therapist',
                    prefixText: 'RM ',
                  ),
                  validator: (value) =>
                      _nonNegativeNumberError(value, 'Enter a valid amount'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextFormField(
                  controller: _counterCommission,
                  enabled: widget.isAdmin && !_saving,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Counter',
                    prefixText: 'RM ',
                  ),
                  validator: (value) =>
                      _nonNegativeNumberError(value, 'Enter a valid amount'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          const _SectionTitle('Room requirement'),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _roomType,
            decoration: const InputDecoration(labelText: 'Room type'),
            items: const [
              DropdownMenuItem(value: 'body_room', child: Text('Body Room')),
              DropdownMenuItem(value: 'foot_chair', child: Text('Foot Chair')),
            ],
            onChanged: _saving
                ? null
                : (value) {
                    if (value != null) _setDirty(() => _roomType = value);
                  },
          ),
          if (_editing && widget.isAdmin) ...[
            const SizedBox(height: 28),
            Divider(color: context.appBorder),
            const SizedBox(height: 16),
            Text(
              'Danger zone',
              style: TextStyle(
                color: AppColors.danger,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Use Inactive for services you may need to restore. Delete is permanent.',
              style: TextStyle(color: context.appMuted, fontSize: 12),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: _saving ? null : _delete,
              icon: const Icon(Icons.delete_outline),
              label: const Text('Delete Service'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.danger,
                side: const BorderSide(color: AppColors.danger),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildMedia(ServiceCatalogueItem previewService) {
    final hasImage =
        _imagePreview != null ||
        (!_imageRemoved && (widget.service?.imageUrl.isNotEmpty ?? false));
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(18, 20, 18, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionTitle('Service image'),
          const SizedBox(height: 6),
          Text(
            'This image appears on service cards and can also be reused by public booking.',
            style: TextStyle(color: context.appMuted, fontSize: 12),
          ),
          const SizedBox(height: 22),
          Center(
            child: _ServiceAvatar(
              service: previewService,
              size: 132,
              preview: _imagePreview,
              imageRemoved: _imageRemoved,
            ),
          ),
          const SizedBox(height: 22),
          if (!widget.isAdmin)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: context.appCanvas,
                borderRadius: BorderRadius.circular(AppRadius.card),
                border: Border.all(color: context.appBorder),
              ),
              child: Row(
                children: [
                  Icon(Icons.lock_outline, color: context.appMuted, size: 19),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      'Only an admin can change service images.',
                      style: TextStyle(color: context.appMuted, fontSize: 12),
                    ),
                  ),
                ],
              ),
            )
          else ...[
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _saving ? null : _pickImage,
                icon: const Icon(Icons.upload_outlined),
                label: Text(hasImage ? 'Replace Image' : 'Upload Image'),
              ),
            ),
            if (hasImage) ...[
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: TextButton.icon(
                  onPressed: _saving
                      ? null
                      : () => _setDirty(() {
                          _imagePreview = null;
                          _imageRemoved = true;
                        }),
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Remove Image'),
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.danger,
                  ),
                ),
              ),
            ],
          ],
          const SizedBox(height: 14),
          Text(
            'JPG, PNG, or WebP · Maximum 5 MB · Square images work best',
            textAlign: TextAlign.center,
            style: TextStyle(color: context.appMuted, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

class _EditorHeader extends StatelessWidget {
  const _EditorHeader({
    required this.editing,
    required this.active,
    required this.saving,
    required this.isFullScreen,
    required this.service,
    required this.preview,
    required this.imageRemoved,
    required this.onActiveChanged,
    required this.onClose,
  });

  final bool editing;
  final bool active;
  final bool saving;
  final bool isFullScreen;
  final ServiceCatalogueItem service;
  final SelectedImage? preview;
  final bool imageRemoved;
  final ValueChanged<bool> onActiveChanged;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: Row(
        children: [
          if (isFullScreen) ...[
            IconButton(
              onPressed: saving ? null : onClose,
              tooltip: 'Back',
              icon: const Icon(Icons.arrow_back),
            ),
            const SizedBox(width: 2),
          ],
          _ServiceAvatar(
            service: service,
            size: 48,
            preview: preview,
            imageRemoved: imageRemoved,
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  editing ? service.name : 'New Service',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: context.appText,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  editing ? service.category : 'Create a catalogue item',
                  style: TextStyle(color: context.appMuted, fontSize: 11.5),
                ),
              ],
            ),
          ),
          Text(
            active ? 'Active' : 'Inactive',
            style: TextStyle(
              color: active ? AppColors.success : context.appMuted,
              fontSize: 11,
              fontWeight: FontWeight.w800,
            ),
          ),
          Transform.scale(
            scale: 0.82,
            child: Switch(
              value: active,
              onChanged: saving ? null : onActiveChanged,
            ),
          ),
          if (!isFullScreen)
            IconButton(
              onPressed: saving ? null : onClose,
              tooltip: 'Close',
              icon: const Icon(Icons.close),
            ),
        ],
      ),
    );
  }
}

class _EditorTabs extends StatelessWidget {
  const _EditorTabs({required this.selected, required this.onChanged});

  final int selected;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: context.appBorder),
          bottom: BorderSide(color: context.appBorder),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: _EditorTab(
              label: 'Details',
              selected: selected == 0,
              onTap: () => onChanged(0),
            ),
          ),
          Expanded(
            child: _EditorTab(
              label: 'Media',
              selected: selected == 1,
              onTap: () => onChanged(1),
            ),
          ),
        ],
      ),
    );
  }
}

class _EditorTab extends StatelessWidget {
  const _EditorTab({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        height: 46,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: selected ? context.appColors.primary : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? context.appColors.primary : context.appMuted,
            fontWeight: FontWeight.w800,
            fontSize: 12,
          ),
        ),
      ),
    );
  }
}

class _EditorFooter extends StatelessWidget {
  const _EditorFooter({
    required this.saving,
    required this.editing,
    required this.onCancel,
    required this.onSave,
  });

  final bool saving;
  final bool editing;
  final VoidCallback onCancel;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: context.appSurface,
        border: Border(top: BorderSide(color: context.appBorder)),
      ),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton(
              onPressed: saving ? null : onCancel,
              child: const Text('Cancel'),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: FilledButton(
              onPressed: saving ? null : onSave,
              child: saving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : Text(editing ? 'Save Changes' : 'Add Service'),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: TextStyle(
        color: context.appText,
        fontSize: 12,
        fontWeight: FontWeight.w800,
      ),
    );
  }
}

String _normalizeRoomType(String value) {
  final normalized = value.trim().toLowerCase().replaceAll(
    RegExp(r'[\s-]+'),
    '_',
  );
  if (normalized.contains('foot')) return 'foot_chair';
  return 'body_room';
}

String? _positiveIntError(String? value, String message) {
  final parsed = int.tryParse(value?.trim() ?? '');
  return parsed == null || parsed <= 0 ? message : null;
}

String? _nonNegativeNumberError(String? value, String message) {
  final parsed = double.tryParse(value?.trim() ?? '');
  return parsed == null || parsed < 0 ? message : null;
}
