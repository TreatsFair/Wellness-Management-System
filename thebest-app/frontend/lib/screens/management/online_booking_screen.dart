import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/outlets/outlet_context.dart';
import '../../core/theme/app_theme.dart';
import '../../data/repositories/image_upload_repository.dart';
import '../../data/repositories/online_booking_repository.dart';
import '../../widgets/adaptive_detail_surface.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/management_catalogue_shell.dart';

enum _OnlineBookingSection { rules, services, closures }

class OnlineBookingScreen extends StatefulWidget {
  const OnlineBookingScreen({super.key});

  @override
  State<OnlineBookingScreen> createState() => _OnlineBookingScreenState();
}

class _OnlineBookingScreenState extends State<OnlineBookingScreen> {
  final _repository = OnlineBookingRepository();
  final _settingsKey = GlobalKey<_SettingsPaneState>();
  late final String _outletId;
  Map<String, dynamic>? _data;
  bool _loading = true;
  _OnlineBookingSection _section = _OnlineBookingSection.rules;
  final _serviceSearchController = TextEditingController();
  bool _servicesGridView = true;
  String? _serviceCategoryFilter;

  @override
  void dispose() {
    _serviceSearchController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _outletId = OutletContext.activeOutletId.value;
    _serviceSearchController.addListener(() => setState(() {}));
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final data = await _repository.load(_outletId);
      if (mounted) {
        setState(() {
          _data = data;
          _loading = false;
        });
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      AppToast.error(context, 'Unable to load online booking: $error');
    }
  }

  List<Map<String, dynamic>> _list(String key) =>
      List<Map<String, dynamic>>.from(_data?[key] as List? ?? const []);

  List<String> _serviceCategories(
    List<Map<String, dynamic>> catalogue,
    List<Map<String, dynamic>> services,
  ) {
    final categories = <String>{};
    for (final item in catalogue) {
      final internal = services
          .where((s) => s['id'] == item['service_id'])
          .firstOrNull;
      final category = internal?['category']?.toString().trim() ?? '';
      if (category.isNotEmpty) categories.add(category);
    }
    final sorted = categories.toList()..sort();
    return sorted;
  }

  @override
  Widget build(BuildContext context) {
    final outlet = OutletContext.outletById(_outletId);
    final catalogue = _list('catalogue');
    final closures = _list('closures');
    final services = _list('services');
    final serviceCategories = _serviceCategories(catalogue, services);
    final contentTitle = switch (_section) {
      _OnlineBookingSection.rules => 'Outlet rules',
      _OnlineBookingSection.services => 'Public services',
      _OnlineBookingSection.closures => 'Closures',
    };
    final countLabel = switch (_section) {
      _OnlineBookingSection.rules => '${outlet.name} public booking controls',
      _OnlineBookingSection.services =>
        '${catalogue.where((item) => item['enabled'] == true).length} live · ${catalogue.length} configured',
      _OnlineBookingSection.closures =>
        '${closures.length} blackout ${closures.length == 1 ? 'period' : 'periods'}',
    };
    final primaryAction = switch (_section) {
      _OnlineBookingSection.rules => CataloguePrimaryButton(
        icon: Icons.save_outlined,
        label: 'Save Rules',
        onPressed: _loading ? null : () => _settingsKey.currentState?._save(),
      ),
      _OnlineBookingSection.services => CataloguePrimaryButton(
        icon: Icons.add,
        label: 'Add Public Service',
        onPressed: () => _editService(null),
      ),
      _OnlineBookingSection.closures => CataloguePrimaryButton(
        icon: Icons.add,
        label: 'Add Closure',
        onPressed: _addClosure,
      ),
    };

    return ManagementCatalogueShell(
      moduleTitle: 'Online Booking',
      moduleSubtitle: 'Public availability and catalogue',
      contentTitle: contentTitle,
      itemCountLabel: countLabel,
      primaryAction: primaryAction,
      navigation: _navigation(catalogue.length, closures.length),
      mobileNavigation: _mobileNavigation(),
      headerActions: _section == _OnlineBookingSection.services
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 190,
                  child: CatalogueSearchField(
                    controller: _serviceSearchController,
                    hintText: 'Search public services...',
                  ),
                ),
                const SizedBox(width: 8),
                CatalogueViewSwitch(
                  gridView: _servicesGridView,
                  onChanged: (value) =>
                      setState(() => _servicesGridView = value),
                ),
              ],
            )
          : null,
      toolbar: _section == _OnlineBookingSection.services
          ? _CategoryTabs(
              categories: serviceCategories,
              selected: _serviceCategoryFilter,
              onSelected: (value) =>
                  setState(() => _serviceCategoryFilter = value),
            )
          : null,
      content: _loading
          ? const Center(child: CircularProgressIndicator())
          : _data == null
          ? Center(
              child: FilledButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Retry'),
              ),
            )
          : switch (_section) {
              _OnlineBookingSection.rules => _SettingsPane(
                key: _settingsKey,
                outletName: outlet.name,
                initial: Map<String, dynamic>.from(_data!['settings'] as Map),
                businessSettings: Map<String, dynamic>.from(
                  _data!['businessSettings'] as Map,
                ),
                onSave: (values) async {
                  await _repository.saveSettings(_outletId, values);
                  await _load();
                },
              ),
              _OnlineBookingSection.services => _ServicesPane(
                catalogue: catalogue,
                services: services,
                rooms: _list('rooms'),
                roomLinks: _list('roomLinks'),
                hours: _list('hours'),
                onView: _viewService,
                gridView: _servicesGridView,
                search: _serviceSearchController.text,
                categoryFilter: _serviceCategoryFilter,
              ),
              _OnlineBookingSection.closures => _ClosuresPane(
                closures: closures,
                onView: _viewClosure,
              ),
            },
    );
  }

  Widget _navigation(int serviceCount, int closureCount) => ListView(
    padding: const EdgeInsets.all(12),
    children: [
      _navigationTile(
        section: _OnlineBookingSection.rules,
        icon: Icons.tune_rounded,
        title: 'Outlet rules',
        subtitle: 'Hours and booking policies',
      ),
      _navigationTile(
        section: _OnlineBookingSection.services,
        icon: Icons.public_outlined,
        title: 'Public services',
        subtitle: 'Published service details',
        count: serviceCount,
      ),
      _navigationTile(
        section: _OnlineBookingSection.closures,
        icon: Icons.event_busy_outlined,
        title: 'Closures',
        subtitle: 'Blackout dates and times',
        count: closureCount,
      ),
    ],
  );

  Widget _navigationTile({
    required _OnlineBookingSection section,
    required IconData icon,
    required String title,
    required String subtitle,
    int? count,
  }) => CatalogueSidebarTile(
    icon: icon,
    title: title,
    subtitle: subtitle,
    count: count,
    selected: _section == section,
    onTap: () => setState(() => _section = section),
  );

  Widget _mobileNavigation() => CatalogueMobileNavigation(
    children: [
      for (final section in _OnlineBookingSection.values)
        CatalogueNavigationChip(
          label: switch (section) {
            _OnlineBookingSection.rules => 'Outlet rules',
            _OnlineBookingSection.services => 'Public services',
            _OnlineBookingSection.closures => 'Closures',
          },
          selected: _section == section,
          onTap: () => setState(() => _section = section),
        ),
    ],
  );

  Future<void> _editService(Map<String, dynamic>? item) async {
    final result = await showAdaptiveDetailSurface<_ServiceDraft>(
      context: context,
      builder: (drawerContext, isFullScreen) => _OnlineServiceDialog(
        item: item,
        services: _list('services'),
        rooms: _list('rooms'),
        roomLinks: _list('roomLinks'),
        hours: _list('hours'),
        isFullScreen: isFullScreen,
        onDelete: item == null
            ? null
            : () async {
                await _repository.deleteService(item['id'].toString());
                if (drawerContext.mounted) Navigator.pop(drawerContext);
                await _load();
              },
      ),
    );
    if (result == null) return;
    final catalogueId = await _repository.saveService(
      outletId: _outletId,
      id: item?['id']?.toString(),
      values: result.values,
      roomIds: result.roomIds,
      hours: result.hours,
    );
    final previousUrl = item?['public_image_url']?.toString() ?? '';
    if (result.imagePreview != null) {
      final url = await ImageUploadRepository().uploadImage(
        image: result.imagePreview!,
        folder: 'online-booking',
        id: catalogueId,
        previousUrl: previousUrl,
      );
      await _repository.updateServiceImage(catalogueId, url);
    } else if (result.imageRemoved && previousUrl.isNotEmpty) {
      await ImageUploadRepository().removePublicUrl(previousUrl);
    }
    await _load();
  }

  Future<void> _viewService(Map<String, dynamic> item) async {
    final internal = _list(
      'services',
    ).where((service) => service['id'] == item['service_id']).firstOrNull;
    final edit = await showAdaptiveDetailSurface<bool>(
      context: context,
      builder: (drawerContext, isFullScreen) =>
          ManagementCatalogueDetailSurface(
            title: item['public_name']?.toString().trim().isNotEmpty == true
                ? item['public_name'].toString()
                : 'Draft public service',
            subtitle: item['enabled'] == true ? 'Live online' : 'Not published',
            isFullScreen: isFullScreen,
            footer: CatalogueDetailEditButton(
              label: 'Edit Public Service',
              onPressed: () => Navigator.pop(drawerContext, true),
            ),
            child: _PublicServiceDetails(item: item, internal: internal),
          ),
    );
    if (edit == true && mounted) await _editService(item);
  }

  Future<void> _addClosure() async {
    final date = await showDatePicker(
      context: context,
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      initialDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (date == null || !mounted) return;
    var fullDay = true;
    final start = TextEditingController(text: '11:00');
    final end = TextEditingController(text: '12:00');
    final reason = TextEditingController();
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: const Text('Add closure'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Close the full day'),
                  value: fullDay,
                  onChanged: (value) => setLocal(() => fullDay = value),
                ),
                if (!fullDay) ...[
                  _field(start, 'From', '11:00'),
                  const SizedBox(height: 10),
                  _field(end, 'Until', '12:00'),
                ],
                const SizedBox(height: 12),
                _field(reason, 'Internal reason', 'Maintenance, holiday…'),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
    if (accepted == true) {
      await _repository.addClosure({
        'outlet_id': _outletId,
        'closure_date':
            '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}',
        'is_full_day': fullDay,
        'start_time': fullDay ? null : start.text.trim(),
        'end_time': fullDay ? null : end.text.trim(),
        'internal_reason': reason.text.trim(),
      });
      await _load();
    }
    start.dispose();
    end.dispose();
    reason.dispose();
  }

  Future<void> _viewClosure(Map<String, dynamic> closure) async {
    final manage = await showAdaptiveDetailSurface<bool>(
      context: context,
      builder: (drawerContext, isFullScreen) =>
          ManagementCatalogueDetailSurface(
            title: closure['closure_date'].toString(),
            subtitle: closure['is_full_day'] == true
                ? 'Full-day closure'
                : 'Partial closure',
            isFullScreen: isFullScreen,
            footer: CatalogueDetailEditButton(
              label: 'Manage Closure',
              onPressed: () => Navigator.pop(drawerContext, true),
            ),
            child: _ClosureDetails(closure: closure),
          ),
    );
    if (manage == true && mounted) await _manageClosure(closure);
  }

  Future<void> _manageClosure(Map<String, dynamic> closure) async {
    await showAdaptiveDetailSurface<void>(
      context: context,
      builder: (drawerContext, isFullScreen) => ManagementCatalogueDetailSurface(
        title: 'Manage Closure',
        subtitle: closure['closure_date'].toString(),
        isFullScreen: isFullScreen,
        footer: OutlinedButton(
          onPressed: () => Navigator.pop(drawerContext),
          child: const Text('Close'),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _ClosureDetails(closure: closure),
            const SizedBox(height: 18),
            _DangerZone(
              title: 'Remove closure',
              description:
                  'This date or time will become bookable again if normal availability allows it.',
              buttonLabel: 'Remove Closure',
              onPressed: () async {
                final confirmed = await showDialog<bool>(
                  context: drawerContext,
                  builder: (dialogContext) => AlertDialog(
                    title: const Text('Remove this closure?'),
                    content: const Text(
                      'Customers may be able to book this period again.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(dialogContext, false),
                        child: const Text('Cancel'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(dialogContext, true),
                        style: FilledButton.styleFrom(
                          backgroundColor: Theme.of(
                            dialogContext,
                          ).colorScheme.error,
                        ),
                        child: const Text('Remove'),
                      ),
                    ],
                  ),
                );
                if (confirmed != true) return;
                await _repository.deleteClosure(closure['id'].toString());
                if (drawerContext.mounted) Navigator.pop(drawerContext);
                await _load();
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingsPane extends StatefulWidget {
  const _SettingsPane({
    super.key,
    required this.outletName,
    required this.initial,
    required this.businessSettings,
    required this.onSave,
  });
  final String outletName;
  final Map<String, dynamic> initial;
  final Map<String, dynamic> businessSettings;
  final Future<void> Function(Map<String, dynamic>) onSave;
  @override
  State<_SettingsPane> createState() => _SettingsPaneState();
}

class _SettingsPaneState extends State<_SettingsPane> {
  final form = GlobalKey<FormState>();
  late bool enabled, therapistSelection, sameDayBooking;
  late final TextEditingController open, close, notice, interval, bookingWindow;
  bool saving = false;

  String _businessTime(String key) {
    final value = widget.businessSettings[key]?.toString() ?? '';
    return value.length >= 5 ? value.substring(0, 5) : '--:--';
  }

  @override
  void initState() {
    super.initState();
    enabled = widget.initial['online_booking_enabled'] == true;
    therapistSelection =
        widget.initial['customer_therapist_selection_allowed'] != false;
    sameDayBooking = widget.initial['same_day_booking_allowed'] == true;
    open = TextEditingController(
      text:
          widget.initial['public_open_time']?.toString().substring(0, 5) ??
          '09:00',
    );
    close = TextEditingController(
      text:
          widget.initial['public_close_time']?.toString().substring(0, 5) ??
          '21:00',
    );
    notice = TextEditingController(
      text: '${widget.initial['minimum_advance_minutes'] ?? 60}',
    );
    interval = TextEditingController(
      text: '${widget.initial['slot_interval_minutes'] ?? 30}',
    );
    bookingWindow = TextEditingController(
      text: '${widget.initial['maximum_booking_days'] ?? 7}',
    );
  }

  @override
  void dispose() {
    open.dispose();
    close.dispose();
    notice.dispose();
    interval.dispose();
    bookingWindow.dispose();
    super.dispose();
  }

  String? _timeValidator(String? value) {
    final match = RegExp(
      r'^(\d{1,2}):(\d{2})$',
    ).firstMatch(value?.trim() ?? '');
    if (match == null) return 'Use HH:MM';
    final hour = int.tryParse(match.group(1) ?? '');
    final minute = int.tryParse(match.group(2) ?? '');
    if (hour == null || minute == null || hour > 23 || minute > 59) {
      return 'Enter a valid time';
    }
    return null;
  }

  String? _numberValidator(
    String? value, {
    required int minimum,
    required int maximum,
  }) {
    final parsed = int.tryParse(value?.trim() ?? '');
    if (parsed == null) return 'Enter a whole number';
    if (parsed < minimum || parsed > maximum) {
      return '$minimum to $maximum';
    }
    return null;
  }

  Widget _numberField({
    required TextEditingController controller,
    required String label,
    required String unit,
    required IconData icon,
    required int minimum,
    required int maximum,
  }) => TextFormField(
    controller: controller,
    keyboardType: TextInputType.number,
    autovalidateMode: AutovalidateMode.onUserInteraction,
    decoration: InputDecoration(
      labelText: label,
      suffixText: unit,
      prefixIcon: Icon(icon),
      border: const OutlineInputBorder(),
    ),
    validator: (value) =>
        _numberValidator(value, minimum: minimum, maximum: maximum),
  );

  Future<void> _save() async {
    if (saving || form.currentState?.validate() != true) return;
    if (_timeToMinutes(close.text) == _timeToMinutes(open.text)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Public opening and closing must be different'),
        ),
      );
      return;
    }

    setState(() => saving = true);
    try {
      await widget.onSave({
        'online_booking_enabled': enabled,
        'public_open_time': open.text.trim(),
        'public_close_time': close.text.trim(),
        'minimum_advance_minutes': int.parse(notice.text.trim()),
        'slot_interval_minutes': int.parse(interval.text.trim()),
        'maximum_booking_days': int.parse(bookingWindow.text.trim()),
        'same_day_booking_allowed': sameDayBooking,
        'customer_therapist_selection_allowed': therapistSelection,
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Online booking rules saved')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Unable to save outlet rules: $error')),
      );
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Form(
    key: form,
    child: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        _card(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.outletName,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                'Public booking stays offline until this switch and at least one complete service are enabled.',
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Online booking enabled'),
                value: enabled,
                onChanged: (v) => setState(() => enabled = v),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _card(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Public hours',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 6),
              Text(
                'Outlet operating hours: ${_businessTime('open_time')} - ${_businessTime('close_time')}. '
                'These come from Business Settings and are shown on the public outlet card.',
                style: const TextStyle(color: Color(0xFF536274), height: 1.4),
              ),
              const SizedBox(height: 6),
              const Text(
                'Public opening and closing only limit when customers can book online. '
                'They may be narrower than the outlet hours and do not change the timetable. '
                'A closing time of 00:00 means midnight at the end of the day.',
                style: TextStyle(color: Color(0xFF536274), height: 1.4),
              ),
              const SizedBox(height: 12),
              LayoutBuilder(
                builder: (context, constraints) {
                  final opening = _field(
                    open,
                    'Public opening',
                    '11:00',
                    validator: _timeValidator,
                  );
                  final closing = _field(
                    close,
                    'Public closing',
                    '22:00',
                    validator: _timeValidator,
                  );
                  if (constraints.maxWidth < 460) {
                    return Column(
                      children: [opening, const SizedBox(height: 12), closing],
                    );
                  }
                  return Row(
                    children: [
                      Expanded(child: opening),
                      const SizedBox(width: 12),
                      Expanded(child: closing),
                    ],
                  );
                },
              ),
              const SizedBox(height: 12),
              _field(
                notice,
                'Minimum advance notice (minutes)',
                '60',
                number: true,
                validator: (value) =>
                    _numberValidator(value, minimum: 0, maximum: 10080),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Divider(height: 1),
              ),
              const Text(
                'Scheduling',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 12),
              LayoutBuilder(
                builder: (context, constraints) {
                  final startInterval = _numberField(
                    controller: interval,
                    label: 'Start interval',
                    unit: 'minutes',
                    icon: Icons.schedule_outlined,
                    minimum: 5,
                    maximum: 120,
                  );
                  final horizon = _numberField(
                    controller: bookingWindow,
                    label: 'Booking window',
                    unit: 'days',
                    icon: Icons.date_range_outlined,
                    minimum: 1,
                    maximum: 90,
                  );
                  if (constraints.maxWidth < 460) {
                    return Column(
                      children: [
                        startInterval,
                        const SizedBox(height: 12),
                        horizon,
                      ],
                    );
                  }
                  return Row(
                    children: [
                      Expanded(child: startInterval),
                      const SizedBox(width: 12),
                      Expanded(child: horizon),
                    ],
                  );
                },
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                secondary: const Icon(Icons.today_outlined),
                title: const Text('Allow same-day bookings'),
                subtitle: const Text('Minimum advance notice still applies'),
                value: sameDayBooking,
                onChanged: (value) => setState(() => sameDayBooking = value),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Allow therapist gender preference'),
                subtitle: const Text('Names are never shown publicly'),
                value: therapistSelection,
                onChanged: (v) => setState(() => therapistSelection = v),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _CategoryTabs extends StatelessWidget {
  const _CategoryTabs({
    required this.categories,
    required this.selected,
    required this.onSelected,
  });

  final List<String> categories;
  final String? selected;
  final ValueChanged<String?> onSelected;

  @override
  Widget build(BuildContext context) {
    final tabs = <String?>[null, ...categories];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: tabs.map((tab) {
          final active = selected == tab;
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: InkWell(
              onTap: () => onSelected(tab),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(4, 6, 4, 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      tab ?? 'All',
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w800,
                        color: active
                            ? context.appColors.primary
                            : context.appMuted,
                      ),
                    ),
                    const SizedBox(height: 6),
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 160),
                      height: 3,
                      width: active ? 32 : 0,
                      decoration: BoxDecoration(
                        color: context.appColors.primary,
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

class _ServicesPane extends StatelessWidget {
  const _ServicesPane({
    required this.catalogue,
    required this.services,
    required this.rooms,
    required this.roomLinks,
    required this.hours,
    required this.onView,
    required this.gridView,
    required this.search,
    required this.categoryFilter,
  });
  final List<Map<String, dynamic>> catalogue, services, rooms, roomLinks, hours;
  final void Function(Map<String, dynamic>) onView;
  final bool gridView;
  final String search;
  final String? categoryFilter;

  Map<String, dynamic>? _internalFor(Map<String, dynamic> item) =>
      services.where((s) => s['id'] == item['service_id']).firstOrNull;

  @override
  Widget build(BuildContext context) {
    if (catalogue.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(20),
          child: Text('No public services configured yet.'),
        ),
      );
    }
    final query = search.trim().toLowerCase();
    final visible = catalogue.where((item) {
      final internal = _internalFor(item);
      if (categoryFilter != null &&
          (internal?['category']?.toString().trim() ?? '') !=
              categoryFilter) {
        return false;
      }
      if (query.isEmpty) return true;
      final publicName = (item['public_name']?.toString() ?? '')
          .toLowerCase();
      final internalName = (internal?['name']?.toString() ?? '')
          .toLowerCase();
      return publicName.contains(query) || internalName.contains(query);
    }).toList();

    if (visible.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(20),
          child: Text('No public services match this filter.'),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final padding = constraints.maxWidth >= 900 ? 24.0 : 16.0;
        final cardHeight =
            context.managementCatalogueCardHeight +
            (constraints.maxWidth < 600 ? 16 : 20);
        if (!gridView) {
          return ListView.separated(
            padding: EdgeInsets.fromLTRB(padding, 16, padding, 28),
            itemCount: visible.length,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (context, index) {
              final item = visible[index];
              return _PublicServiceListTile(
                item: item,
                internal: _internalFor(item),
                onTap: () => onView(item),
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
            final item = visible[index];
            return _PublicServiceCard(
              item: item,
              internal: _internalFor(item),
              onTap: () => onView(item),
            );
          },
        );
      },
    );
  }
}

class _PublicServiceCard extends StatelessWidget {
  const _PublicServiceCard({
    required this.item,
    required this.internal,
    required this.onTap,
  });

  final Map<String, dynamic> item;
  final Map<String, dynamic>? internal;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final narrowGrid = MediaQuery.sizeOf(context).width < 600;
    final name = (item['public_name'] as String?)?.trim().isNotEmpty == true
        ? item['public_name'] as String
        : 'Draft public service';
    final live = item['enabled'] == true;
    final category = internal?['category']?.toString().trim() ?? '';
    return Material(
      color: context.appSurface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
        side: BorderSide(color: context.appBorder),
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
                  _PublicServiceAvatar(
                    name: name,
                    imageUrl: item['public_image_url']?.toString() ?? '',
                    size: narrowGrid ? 40 : 46,
                  ),
                  SizedBox(width: narrowGrid ? 8 : 11),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: context.appText,
                            fontWeight: FontWeight.w800,
                            height: 1.2,
                          ),
                        ),
                        if (category.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          _PublicCategoryBadge(category: category),
                        ],
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
                '${internal?['name'] ?? 'Missing internal service'} · ${internal?['duration'] ?? 0} min',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: context.appMuted, fontSize: 12),
              ),
              const SizedBox(height: 5),
              Text(
                'RM ${item['display_price'] ?? 0}',
                style: TextStyle(
                  color: context.appText,
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
              SizedBox(height: narrowGrid ? 8 : 12),
              Align(
                alignment: Alignment.centerRight,
                child: _PublicStatusBadge(live: live),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PublicServiceListTile extends StatelessWidget {
  const _PublicServiceListTile({
    required this.item,
    required this.internal,
    required this.onTap,
  });

  final Map<String, dynamic> item;
  final Map<String, dynamic>? internal;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final name = (item['public_name'] as String?)?.trim().isNotEmpty == true
        ? item['public_name'] as String
        : 'Draft public service';
    final live = item['enabled'] == true;
    final category = internal?['category']?.toString().trim() ?? '';
    return Material(
      color: context.appSurface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
        side: BorderSide(color: context.appBorder),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.card),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              _PublicServiceAvatar(
                name: name,
                imageUrl: item['public_image_url']?.toString() ?? '',
                size: 48,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
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
                        if (category.isNotEmpty)
                          _PublicCategoryBadge(category: category),
                        _PublicStatusBadge(live: live),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${internal?['name'] ?? 'Missing internal service'} · ${internal?['duration'] ?? 0} min · RM ${item['display_price'] ?? 0}',
                      maxLines: 2,
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

class _PublicServiceAvatar extends StatelessWidget {
  const _PublicServiceAvatar({
    required this.name,
    required this.imageUrl,
    required this.size,
    this.preview,
    this.imageRemoved = false,
  });

  final String name;
  final String imageUrl;
  final double size;
  final SelectedImage? preview;
  final bool imageRemoved;

  @override
  Widget build(BuildContext context) {
    final url = imageRemoved ? '' : imageUrl;
    final fallback = Container(
      width: size,
      height: size,
      color: _publicAvatarColor(name),
      alignment: Alignment.center,
      child: Text(
        _publicServiceInitials(name),
        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800),
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

class _PublicCategoryBadge extends StatelessWidget {
  const _PublicCategoryBadge({required this.category});

  final String category;

  @override
  Widget build(BuildContext context) {
    final color = _publicCategoryColor(category);
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

class _PublicStatusBadge extends StatelessWidget {
  const _PublicStatusBadge({required this.live});

  final bool live;

  @override
  Widget build(BuildContext context) {
    final color = live ? AppColors.success : context.appMuted;
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
          live ? 'Live' : 'Not published',
          style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w800),
        ),
      ],
    );
  }
}

Color _publicCategoryColor(String category) {
  final value = category.toLowerCase();
  if (value.contains('package')) return const Color(0xFF7C3AED);
  if (value.contains('add')) return const Color(0xFFD97706);
  if (value.contains('massage')) return const Color(0xFF2563EB);
  return AppColors.primary;
}

Color _publicAvatarColor(String seed) {
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

String _publicServiceInitials(String name) {
  final parts = name
      .trim()
      .split(RegExp(r'\s+'))
      .where((part) => part.isNotEmpty)
      .toList();
  if (parts.isEmpty) return '?';
  if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
  return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
}

class _PublicServiceDetails extends StatelessWidget {
  const _PublicServiceDetails({required this.item, required this.internal});

  final Map<String, dynamic> item;
  final Map<String, dynamic>? internal;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _OnlineDetailCard(
        icon: item['enabled'] == true ? Icons.public : Icons.public_off,
        title: 'Publishing',
        children: [
          _DetailLine(
            label: 'Status',
            value: item['enabled'] == true ? 'Live online' : 'Not published',
          ),
          _DetailLine(
            label: 'Public price',
            value: item['show_price'] == false
                ? 'Hidden'
                : 'RM ${item['display_price'] ?? 0}',
          ),
          _DetailLine(
            label: 'Display order',
            value: '${item['display_order'] ?? 0}',
            last: true,
          ),
        ],
      ),
      const SizedBox(height: 12),
      _OnlineDetailCard(
        icon: Icons.link_outlined,
        title: 'Linked service',
        children: [
          _DetailLine(
            label: 'Internal service',
            value: internal?['name']?.toString() ?? 'Missing service',
          ),
          _DetailLine(
            label: 'Treatment time',
            value: '${internal?['duration'] ?? 0} min',
          ),
          _DetailLine(
            label: 'Cleanup buffer',
            value: '${internal?['buffer_after_minutes'] ?? 0} min',
            last: true,
          ),
        ],
      ),
      const SizedBox(height: 12),
      _OnlineDetailCard(
        icon: Icons.description_outlined,
        title: 'Public information',
        children: [
          Text(
            item['short_description']?.toString().trim().isNotEmpty == true
                ? item['short_description'].toString()
                : 'No public description',
            style: TextStyle(color: context.appText, height: 1.45),
          ),
        ],
      ),
    ],
  );
}

class _ClosureDetails extends StatelessWidget {
  const _ClosureDetails({required this.closure});

  final Map<String, dynamic> closure;

  @override
  Widget build(BuildContext context) => _OnlineDetailCard(
    icon: Icons.event_busy_outlined,
    title: 'Closure information',
    children: [
      _DetailLine(label: 'Date', value: closure['closure_date'].toString()),
      _DetailLine(
        label: 'Period',
        value: closure['is_full_day'] == true
            ? 'Full day'
            : '${closure['start_time']} – ${closure['end_time']}',
      ),
      _DetailLine(
        label: 'Internal reason',
        value: closure['internal_reason']?.toString().trim().isNotEmpty == true
            ? closure['internal_reason'].toString()
            : 'No reason recorded',
        last: true,
      ),
    ],
  );
}

class _OnlineDetailCard extends StatelessWidget {
  const _OnlineDetailCard({
    required this.icon,
    required this.title,
    required this.children,
  });

  final IconData icon;
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: context.appSurface,
      border: Border.all(color: context.appBorder),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 19, color: context.appColors.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  color: context.appText,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        ...children,
      ],
    ),
  );
}

class _DetailLine extends StatelessWidget {
  const _DetailLine({
    required this.label,
    required this.value,
    this.last = false,
  });

  final String label;
  final String value;
  final bool last;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 4,
              child: Text(label, style: TextStyle(color: context.appMuted)),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 6,
              child: Text(
                value,
                textAlign: TextAlign.right,
                style: TextStyle(
                  color: context.appText,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
      if (!last) Divider(height: 1, color: context.appBorder),
    ],
  );
}

class _DangerZone extends StatelessWidget {
  const _DangerZone({
    required this.title,
    required this.description,
    required this.buttonLabel,
    required this.onPressed,
  });

  final String title;
  final String description;
  final String buttonLabel;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final error = Theme.of(context).colorScheme.error;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(
          context,
        ).colorScheme.errorContainer.withValues(alpha: 0.45),
        border: Border.all(color: error),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(color: error, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 4),
          Text(description),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: onPressed,
            icon: const Icon(Icons.delete_outline),
            label: Text(buttonLabel),
            style: OutlinedButton.styleFrom(foregroundColor: error),
          ),
        ],
      ),
    );
  }
}

class _ServiceDraft {
  const _ServiceDraft(
    this.values,
    this.roomIds,
    this.hours, {
    this.imagePreview,
    this.imageRemoved = false,
  });
  final Map<String, dynamic> values;
  final Set<String> roomIds;
  final List<Map<String, dynamic>> hours;
  final SelectedImage? imagePreview;
  final bool imageRemoved;
}

class _OnlineServiceDialog extends StatefulWidget {
  const _OnlineServiceDialog({
    required this.item,
    required this.services,
    required this.rooms,
    required this.roomLinks,
    required this.hours,
    required this.isFullScreen,
    this.onDelete,
  });
  final Map<String, dynamic>? item;
  final List<Map<String, dynamic>> services, rooms, roomLinks, hours;
  final bool isFullScreen;
  final Future<void> Function()? onDelete;
  @override
  State<_OnlineServiceDialog> createState() => _OnlineServiceDialogState();
}

class _OnlineServiceDialogState extends State<_OnlineServiceDialog> {
  final form = GlobalKey<FormState>();
  final _imageRepository = ImageUploadRepository();
  late String? serviceId;
  late final TextEditingController name, description, price, order, capacity, start, end;
  late bool enabled, showPrice, custom;
  late Set<String> roomIds;
  late String _existingImageUrl;
  SelectedImage? _imagePreview;
  bool _imageRemoved = false;
  final weekdays = <int>{0, 1, 2, 3, 4, 5, 6};
  @override
  void initState() {
    super.initState();
    final i = widget.item ?? {};
    serviceId = i['service_id']?.toString();
    name = TextEditingController(text: i['public_name']?.toString() ?? '');
    description = TextEditingController(
      text: i['short_description']?.toString() ?? '',
    );
    _existingImageUrl = i['public_image_url']?.toString() ?? '';
    price = TextEditingController(text: '${i['display_price'] ?? ''}');
    order = TextEditingController(text: '${i['display_order'] ?? 0}');
    capacity = TextEditingController(
      text: '${i['maximum_concurrent_bookings'] ?? 3}',
    );
    enabled = i['enabled'] == true;
    showPrice = i['show_price'] != false;
    custom = i['use_custom_hours'] == true;
    final id = i['id']?.toString();
    roomIds = widget.roomLinks
        .where((r) => r['online_booking_service_id'].toString() == id)
        .map((r) => r['room_id'].toString())
        .toSet();
    final existing = widget.hours
        .where((h) => h['online_booking_service_id'].toString() == id)
        .toList();
    start = TextEditingController(
      text: existing.isEmpty
          ? '11:00'
          : existing.first['start_time'].toString().substring(0, 5),
    );
    end = TextEditingController(
      text: existing.isEmpty
          ? '22:00'
          : existing.first['end_time'].toString().substring(0, 5),
    );
  }

  @override
  void dispose() {
    for (final c in [
      name,
      description,
      price,
      order,
      capacity,
      start,
      end,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Map<String, dynamic>? internal;
    for (final service in widget.services) {
      if (service['id'].toString() == serviceId) {
        internal = service;
        break;
      }
    }
    return ManagementCatalogueDetailSurface(
      title: widget.item == null ? 'Add Public Service' : 'Edit Public Service',
      subtitle: 'Public details, availability and publishing',
      isFullScreen: widget.isFullScreen,
      footer: Row(
        children: [
          Expanded(
            child: OutlinedButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: FilledButton(
              onPressed: () => _saveDraft(internal),
              child: const Text('Save Changes'),
            ),
          ),
        ],
      ),
      child: Form(
        key: form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DropdownButtonFormField<String>(
              initialValue: serviceId,
              decoration: const InputDecoration(
                labelText: 'Linked internal service',
              ),
              items: widget.services
                  .map(
                    (s) => DropdownMenuItem(
                      value: s['id'].toString(),
                      child: Text(s['name'].toString()),
                    ),
                  )
                  .toList(),
              onChanged: widget.item == null
                  ? (v) => setState(() => serviceId = v)
                  : null,
              validator: (v) => v == null ? 'Required' : null,
            ),
            if (internal != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Scheduling duration: ${internal['duration']} minutes • Cleanup buffer: ${internal['buffer_after_minutes'] ?? 0} minutes (inherited)',
                ),
              ),
            const SizedBox(height: 12),
            _field(name, 'Public name', '', required: true),
            const SizedBox(height: 12),
            _field(
              description,
              'Short public description',
              '',
              required: true,
              lines: 3,
            ),
            const SizedBox(height: 12),
            Text(
              'Public image',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: context.appMuted,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _PublicServiceAvatar(
                  name: name.text.trim().isEmpty ? 'Service' : name.text.trim(),
                  imageUrl: _existingImageUrl,
                  size: 64,
                  preview: _imagePreview,
                  imageRemoved: _imageRemoved,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed: _pickImage,
                        icon: const Icon(Icons.upload_outlined, size: 18),
                        label: Text(_hasImage ? 'Replace Image' : 'Upload Image'),
                      ),
                      if (_hasImage)
                        TextButton.icon(
                          onPressed: _removeImage,
                          icon: const Icon(Icons.delete_outline, size: 18),
                          label: const Text('Remove Image'),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _field(
                    price,
                    'Display price',
                    '0',
                    number: true,
                    required: true,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _field(order, 'Display order', '0', number: true),
                ),
              ],
            ),
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'The cleanup buffer is controlled by the linked internal service and reserves both therapist and room. Customers only see treatment time.',
                style: TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Show price publicly'),
              value: showPrice,
              onChanged: (v) => setState(() => showPrice = v),
            ),
            const Divider(),
            const Text(
              'Eligible rooms / beds',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            ...widget.rooms.map(
              (r) => CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('${r['name']} (${r['total_slots'] ?? 1} slots)'),
                value: roomIds.contains(r['id'].toString()),
                onChanged: (v) => setState(
                  () => v == true
                      ? roomIds.add(r['id'].toString())
                      : roomIds.remove(r['id'].toString()),
                ),
              ),
            ),
            Row(
              children: [
                Expanded(
                  child: _field(
                    capacity,
                    'Max bookings per timeslot',
                    '3',
                    number: true,
                    helper:
                        'How many of this service the website may sell at the '
                        'same time. Counts online bookings only — walk-ins and '
                        'staff-created appointments are not deducted. Therapist '
                        'and room availability still apply on top, so a slot can '
                        'show fewer than this.',
                  ),
                ),
              ],
            ),
            if (internal != null) ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFF8FAFC),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFFE5E7EB)),
                ),
                child: Text(
                  'After-service cleanup buffer: ${internal['buffer_after_minutes'] ?? 0} minutes',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF374151),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Use custom service hours'),
              subtitle: const Text('Otherwise inherits outlet public hours'),
              value: custom,
              onChanged: (v) => setState(() => custom = v),
            ),
            if (custom)
              Row(
                children: [
                  Expanded(child: _field(start, 'Available from', '11:00')),
                  const SizedBox(width: 10),
                  Expanded(child: _field(end, 'Available until', '22:00')),
                ],
              ),
            const Divider(),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Enabled'),
              value: enabled,
              onChanged: (v) => setState(() => enabled = v),
            ),
            if (widget.onDelete != null) ...[
              const SizedBox(height: 18),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.errorContainer.withValues(alpha: 0.45),
                  border: Border.all(
                    color: Theme.of(context).colorScheme.error,
                  ),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Danger Zone',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Removing this public listing does not delete the internal service.',
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: _confirmDelete,
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('Remove Public Listing'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  bool get _hasImage =>
      _imagePreview != null || (!_imageRemoved && _existingImageUrl.isNotEmpty);

  Future<void> _pickImage() async {
    try {
      final image = await _imageRepository.pickImage();
      if (image == null || !mounted) return;
      setState(() {
        _imagePreview = image;
        _imageRemoved = false;
      });
    } catch (error) {
      if (mounted) AppToast.error(context, error.toString());
    }
  }

  void _removeImage() {
    setState(() {
      _imagePreview = null;
      _imageRemoved = true;
    });
  }

  void _saveDraft(Map<String, dynamic>? internal) {
    if (!form.currentState!.validate() ||
        serviceId == null ||
        roomIds.isEmpty) {
      AppToast.error(
        context,
        'Complete the public fields and select at least one room.',
      );
      return;
    }
    if (!_hasImage) {
      AppToast.error(context, 'Add a public image before saving.');
      return;
    }
    final configuredHours = custom
        ? weekdays
              .map(
                (day) => <String, dynamic>{
                  'day_of_week': day,
                  'start_time': start.text.trim(),
                  'end_time': end.text.trim(),
                },
              )
              .toList()
        : <Map<String, dynamic>>[];
    Navigator.pop(
      context,
      _ServiceDraft(
        {
          'service_id': serviceId,
          'public_name': name.text.trim(),
          'short_description': description.text.trim(),
          if (_imagePreview == null)
            'public_image_url': _imageRemoved ? '' : _existingImageUrl,
          'display_price': double.tryParse(price.text) ?? 0,
          'display_order': int.tryParse(order.text) ?? 0,
          'show_price': showPrice,
          'buffer_before_minutes': 0,
          'buffer_after_minutes':
              int.tryParse(
                internal?['buffer_after_minutes']?.toString() ?? '',
              ) ??
              5,
          'maximum_concurrent_bookings': int.tryParse(capacity.text) ?? 3,
          'use_custom_hours': custom,
          'enabled': enabled,
        },
        roomIds,
        configuredHours,
        imagePreview: _imagePreview,
        imageRemoved: _imageRemoved,
      ),
    );
  }

  Future<void> _confirmDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Remove public listing?'),
        content: const Text(
          'Customers will no longer see this listing. The internal service remains available to staff.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed == true) await widget.onDelete?.call();
  }
}

class _ClosuresPane extends StatelessWidget {
  const _ClosuresPane({required this.closures, required this.onView});
  final List<Map<String, dynamic>> closures;
  final void Function(Map<String, dynamic>) onView;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      if (closures.isEmpty)
        _card(
          const Padding(
            padding: EdgeInsets.all(20),
            child: Center(child: Text('No closures configured.')),
          ),
        ),
      ...closures.map(
        (c) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: _card(
            Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () => onView(c),
                borderRadius: BorderRadius.circular(10),
                child: ListTile(
                  minTileHeight: context.managementCatalogueListHeight,
                  leading: Icon(
                    Icons.event_busy_outlined,
                    color: Theme.of(context).colorScheme.error,
                  ),
                  title: Text(
                    c['closure_date'].toString(),
                    style: TextStyle(
                      color: context.appText,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  subtitle: Text(
                    c['is_full_day'] == true
                        ? 'Full day'
                        : '${c['start_time']} – ${c['end_time']}',
                    style: TextStyle(color: context.appMuted),
                  ),
                  trailing: Icon(
                    Icons.chevron_right_rounded,
                    color: context.appMuted,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ],
  );
}

Widget _card(Widget child) => Builder(
  builder: (context) => Container(
    decoration: BoxDecoration(
      color: context.appSurface,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: context.appBorder),
    ),
    padding: const EdgeInsets.all(8),
    child: child,
  ),
);
Widget _field(
  TextEditingController controller,
  String label,
  String hint, {
  bool number = false,
  bool required = false,
  int lines = 1,
  String? helper,
  String? Function(String?)? validator,
}) => TextFormField(
  controller: controller,
  maxLines: lines,
  keyboardType: number ? TextInputType.number : null,
  decoration: InputDecoration(
    labelText: label,
    hintText: hint,
    helperText: helper,
    helperMaxLines: 4,
    border: const OutlineInputBorder(),
  ),
  validator:
      validator ??
      (v) => required && (v?.trim().isEmpty ?? true) ? 'Required' : null,
);

int _timeToMinutes(String value) {
  final parts = value.trim().split(':');
  if (parts.length != 2) return 0;
  return (int.tryParse(parts[0]) ?? 0) * 60 + (int.tryParse(parts[1]) ?? 0);
}
