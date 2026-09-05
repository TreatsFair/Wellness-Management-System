import 'package:flutter/material.dart';

import '../../core/outlets/outlet_context.dart';
import '../../core/theme/app_theme.dart';
import '../../data/repositories/promotion_repository.dart';
import '../../widgets/adaptive_detail_surface.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/management_catalogue_shell.dart';

class PromotionManagementPane extends StatefulWidget {
  const PromotionManagementPane({
    super.key,
    required this.outletId,
    required this.canEdit,
  });

  final String outletId;
  final bool canEdit;

  @override
  PromotionManagementPaneState createState() => PromotionManagementPaneState();
}

class PromotionManagementPaneState extends State<PromotionManagementPane> {
  final _repository = PromotionRepository();
  List<Map<String, dynamic>> _promotions = [];
  List<Map<String, dynamic>> _services = [];
  List<Map<String, dynamic>> _onlineServices = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant PromotionManagementPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.outletId != widget.outletId) {
      _load();
    }
  }

  Future<void> _load() async {
    if (mounted) setState(() { _loading = true; _error = null; });
    try {
      final results = await Future.wait([
        _repository.list(),
        _repository.services(),
        _repository.onlineServices(),
      ]);
      if (!mounted) return;
      setState(() {
        _promotions = List<Map<String, dynamic>>.from(results[0]);
        _services = List<Map<String, dynamic>>.from(results[1]);
        _onlineServices = List<Map<String, dynamic>>.from(results[2]);
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() { _loading = false; _error = error.toString(); });
    }
  }

  Future<void> openCreate() => _openEditor(null);

  Future<void> _openEditor(Map<String, dynamic>? promotion) async {
    final payload = await showAdaptiveDetailSurface<Map<String, dynamic>>(
      context: context,
      builder: (drawerContext, isFullScreen) => _PromotionEditor(
        initial: promotion,
        services: _services,
        eligibleServices: _onlineServices,
        isFullScreen: isFullScreen,
      ),
    );
    if (payload == null || !mounted) return;
    try {
      final result = await _repository.save(payload);
      if (!mounted) return;
      await _load();
      if (!mounted) return;
      final generated = result['generated_code']?.toString().trim() ?? '';
      AppToast.success(
        context,
        promotion == null ? 'Promotion created' : 'Promotion updated',
        message: generated.isEmpty ? '' : 'Generated code: $generated',
      );
    } catch (error) {
      if (mounted) AppToast.error(context, 'Unable to save promotion: $error');
    }
  }

  Future<void> _toggle(Map<String, dynamic> promotion, bool active) async {
    final id = promotion['promotion_id']?.toString();
    if (id == null || id.isEmpty) return;
    try {
      await _repository.setActive(id, active);
      if (!mounted) return;
      setState(() => promotion['active'] = active);
      AppToast.success(context, active ? 'Promotion enabled' : 'Promotion disabled');
    } catch (error) {
      if (mounted) AppToast.error(context, 'Unable to change promotion status: $error');
    }
  }

  String _benefit(Map<String, dynamic> item) {
    final type = item['benefit_type']?.toString();
    final value = num.tryParse(item['benefit_value']?.toString() ?? '') ?? 0;
    return switch (type) {
      'percentage_discount' => '${_number(value)}% off',
      'fixed_discount' => 'RM ${_number(value)} off',
      'free_addon' => 'Free ${item['free_addon_service_name'] ?? 'add-on'}',
      _ => 'Benefit not configured',
    };
  }

  String _number(num value) => value == value.roundToDouble()
      ? value.toInt().toString()
      : value.toStringAsFixed(2);

  String _date(String? value) {
    final parsed = DateTime.tryParse(value ?? '')?.toLocal();
    if (parsed == null) return 'Now';
    return '${parsed.day.toString().padLeft(2, '0')}/${parsed.month.toString().padLeft(2, '0')}/${parsed.year}';
  }

  List<String> _ids(Object? value) => (value as List? ?? const [])
      .map((item) => item.toString())
      .toList();

  String _outletLabel(String id) => OutletContext.outlets
      .where((outlet) => outlet.id == id)
      .map((outlet) => outlet.name)
      .firstOrNull ?? id;

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: FilledButton.icon(
          onPressed: _load,
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('Retry promotions'),
        ),
      );
    }
    if (_promotions.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.local_offer_outlined, size: 42, color: context.appMuted),
              const SizedBox(height: 12),
              const Text('No promotions yet', style: AppText.heading),
              const SizedBox(height: 6),
              Text(
                'Create a server-validated code for online bookings. Leave outlets or services empty to make it global.',
                textAlign: TextAlign.center,
                style: TextStyle(color: context.appMuted),
              ),
              if (widget.canEdit) ...[
                const SizedBox(height: 18),
                FilledButton.icon(
                  onPressed: openCreate,
                  icon: const Icon(Icons.add),
                  label: const Text('Create promotion'),
                ),
              ],
            ],
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
        itemCount: _promotions.length,
        separatorBuilder: (_, _) => const SizedBox(height: 12),
        itemBuilder: (context, index) => _PromotionCard(
          promotion: _promotions[index],
          canEdit: widget.canEdit,
          benefit: _benefit(_promotions[index]),
          dateLabel: '${_date(_promotions[index]['starts_at']?.toString())} – ${_date(_promotions[index]['ends_at']?.toString())}',
          outletLabel: () {
            final ids = _ids(_promotions[index]['outlet_ids']);
            return ids.isEmpty ? 'All outlets' : ids.map(_outletLabel).join(', ');
          }(),
          onEdit: () => _openEditor(_promotions[index]),
          onToggle: (active) => _toggle(_promotions[index], active),
        ),
      ),
    );
  }
}

class _PromotionCard extends StatelessWidget {
  const _PromotionCard({
    required this.promotion,
    required this.canEdit,
    required this.benefit,
    required this.dateLabel,
    required this.outletLabel,
    required this.onEdit,
    required this.onToggle,
  });

  final Map<String, dynamic> promotion;
  final bool canEdit;
  final String benefit;
  final String dateLabel;
  final String outletLabel;
  final VoidCallback onEdit;
  final ValueChanged<bool> onToggle;

  List<Map<String, dynamic>> get codes => (promotion['codes'] as List? ?? const [])
      .map((item) => Map<String, dynamic>.from(item as Map))
      .toList();

  List<String> get serviceIds => (promotion['service_ids'] as List? ?? const [])
      .map((item) => item.toString())
      .toList();

  @override
  Widget build(BuildContext context) {
    final active = promotion['active'] == true;
    final reserved = promotion['reserved_count'] ?? 0;
    final redeemed = promotion['redeemed_count'] ?? 0;
    final benefitType = promotion['benefit_type']?.toString() ?? '';
    final discountGiven = double.tryParse(
          promotion['redeemed_discount_amount']?.toString() ?? '',
        ) ??
        0;
    final isMonetary = benefitType == 'fixed_discount' ||
        benefitType == 'percentage_discount';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    promotion['name']?.toString() ?? 'Unnamed promotion',
                    style: AppText.heading,
                  ),
                ),
                Switch.adaptive(value: active, onChanged: canEdit ? onToggle : null),
              ],
            ),
            const SizedBox(height: 4),
            Text(benefit, style: TextStyle(color: context.appColors.primary, fontWeight: FontWeight.w800)),
            if ((promotion['description']?.toString() ?? '').trim().isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(promotion['description'].toString(), style: TextStyle(color: context.appMuted)),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _InfoPill(icon: Icons.storefront_outlined, text: outletLabel),
                _InfoPill(icon: Icons.event_outlined, text: dateLabel),
                _InfoPill(icon: Icons.shopping_bag_outlined, text: serviceIds.isEmpty ? 'All services' : '${serviceIds.length} service${serviceIds.length == 1 ? '' : 's'}'),
              ],
            ),
            const Divider(height: 24),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final code in codes)
                  Chip(
                    avatar: const Icon(Icons.confirmation_number_outlined, size: 16),
                    label: Text(code['code']?.toString() ?? ''),
                  ),
                if (codes.isEmpty)
                  const Text('No code assigned', style: TextStyle(color: AppColors.warning)),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Reserved $reserved · Redeemed $redeemed · Released ${promotion['released_count'] ?? 0}',
              style: TextStyle(color: context.appMuted, fontSize: 12),
            ),
            if (isMonetary) ...[
              const SizedBox(height: 4),
              Text(
                'RM ${discountGiven.toStringAsFixed(2)} discounts given',
                style: const TextStyle(
                  color: Color(0xFF4D8B45),
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
            if (canEdit) ...[
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: OutlinedButton.icon(
                  onPressed: onEdit,
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  label: const Text('Edit promotion'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _InfoPill extends StatelessWidget {
  const _InfoPill({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
    decoration: BoxDecoration(
      color: context.appCanvas,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: context.appMuted),
        const SizedBox(width: 5),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 260),
          child: Text(text, overflow: TextOverflow.ellipsis, style: AppText.caption),
        ),
      ],
    ),
  );
}

class _PromotionEditor extends StatefulWidget {
  const _PromotionEditor({
    required this.initial,
    required this.services,
    required this.eligibleServices,
    required this.isFullScreen,
  });

  final Map<String, dynamic>? initial;
  final List<Map<String, dynamic>> services;
  final List<Map<String, dynamic>> eligibleServices;
  final bool isFullScreen;

  @override
  State<_PromotionEditor> createState() => _PromotionEditorState();
}

class _PromotionEditorState extends State<_PromotionEditor> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _description;
  late final TextEditingController _benefitValue;
  late final TextEditingController _maxRedemptions;
  late final TextEditingController _perCustomerLimit;
  late final TextEditingController _minimumSpend;
  late final TextEditingController _maximumDiscount;
  late final TextEditingController _code;
  late String _benefitType;
  late String _usageType;
  late String _addOnMode;
  late bool _active;
  late bool _onlineOnly;
  late bool _generateCode;
  late DateTime _startsAt;
  DateTime? _endsAt;
  late Set<String> _outletIds;
  late Set<String> _serviceIds;
  String? _addOnServiceId;

  static const _benefits = <String, String>{
    'percentage_discount': 'Percentage discount',
    'fixed_discount': 'Fixed discount',
    'free_addon': 'Free add-on',
  };
  static const _usageTypes = <String, String>{
    'single_use': 'Single-use (one redemption)',
    'multi_use': 'Multi-use campaign',
  };
  static const _addOnModes = <String, String>{
    'unsupported': 'Requires scheduled add-on (fail closed)',
    'scheduled': 'Scheduled service segment',
    'no_resource': 'No duration or resource used',
  };

  Map<String, dynamic> get initial => widget.initial ?? const {};

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: initial['name']?.toString() ?? '');
    _description = TextEditingController(text: initial['description']?.toString() ?? '');
    _benefitType = _benefits.containsKey(initial['benefit_type']) ? initial['benefit_type'].toString() : 'percentage_discount';
    _benefitValue = TextEditingController(text: initial['benefit_value']?.toString() ?? '10');
    _usageType = _usageTypes.containsKey(initial['usage_type']) ? initial['usage_type'].toString() : 'single_use';
    _active = initial['active'] == true;
    _onlineOnly = initial.isEmpty || initial['online_booking_only'] != false;
    _startsAt = DateTime.tryParse(initial['starts_at']?.toString() ?? '')?.toLocal() ?? DateTime.now();
    _endsAt = DateTime.tryParse(initial['ends_at']?.toString() ?? '')?.toLocal();
    _maxRedemptions = TextEditingController(text: initial['max_redemptions']?.toString() ?? (_usageType == 'single_use' ? '1' : '100'));
    _perCustomerLimit = TextEditingController(text: initial['per_customer_limit']?.toString() ?? '');
    _minimumSpend = TextEditingController(text: initial['minimum_spend']?.toString() ?? '0');
    _maximumDiscount = TextEditingController(text: initial['maximum_discount']?.toString() ?? '');
    final codes = (initial['codes'] as List? ?? const []);
    _code = TextEditingController(
      text: codes.isEmpty ? '' : Map<String, dynamic>.from(codes.first as Map)['code']?.toString() ?? '',
    );
    _generateCode = false;
    _addOnMode = _addOnModes.containsKey(initial['free_addon_scheduling_mode'])
        ? initial['free_addon_scheduling_mode'].toString()
        : 'unsupported';
    _outletIds = _stringSet(initial['outlet_ids']);
    _serviceIds = _stringSet(initial['service_ids']);
    final existingAddOn = initial['free_addon_service_id']?.toString();
    _addOnServiceId = widget.services.any((service) => service['id']?.toString() == existingAddOn)
        ? existingAddOn
        : null;
  }

  Set<String> _stringSet(Object? value) => (value as List? ?? const [])
      .map((item) => item.toString())
      .toSet();

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    _benefitValue.dispose();
    _maxRedemptions.dispose();
    _perCustomerLimit.dispose();
    _minimumSpend.dispose();
    _maximumDiscount.dispose();
    _code.dispose();
    super.dispose();
  }

  String? _amountValidator(String? value, {bool percentage = false}) {
    final parsed = double.tryParse(value?.trim() ?? '');
    if (parsed == null || parsed < 0) return 'Enter a non-negative amount';
    if (percentage && parsed > 100) return 'Use 0 to 100';
    return null;
  }

  String? _positiveAmountValidator(String? value) {
    final parsed = double.tryParse(value?.trim() ?? '');
    if (parsed == null || parsed <= 0) return 'Enter an amount greater than 0';
    return null;
  }

  String _serviceLabel(Map<String, dynamic> service) {
    final name = service['name']?.toString().trim();
    final duration = int.tryParse(service['duration']?.toString() ?? '');
    final outletId = service['outlet_id']?.toString() ?? '';
    final outlet = OutletContext.outletById(outletId).name;
    final base = duration != null && duration > 0
        ? '${name?.isNotEmpty == true ? name : 'Unnamed'} · $duration min'
        : name?.isNotEmpty == true
        ? name!
        : 'Unnamed';
    return '$base · $outlet';
  }

  String? _optionalIntegerValidator(String? value) {
    if ((value ?? '').trim().isEmpty) return null;
    final parsed = int.tryParse(value!.trim());
    return parsed == null || parsed < 1 ? 'Enter a whole number (at least 1)' : null;
  }

  Future<DateTime?> _pickDateTime(DateTime? current) async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
      initialDate: current ?? now,
    );
    if (date == null || !mounted) return null;
    final time = await showTimePicker(
      context: context,
      initialTime: current == null ? TimeOfDay.now() : TimeOfDay.fromDateTime(current),
    );
    if (time == null) return null;
    return DateTime(date.year, date.month, date.day, time.hour, time.minute);
  }

  String _dateTimeLabel(DateTime value) =>
      '${MaterialLocalizations.of(context).formatMediumDate(value)} ${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(value))}';

  Widget _textField(
    TextEditingController controller,
    String label, {
    String? hint,
    int maxLines = 1,
    TextInputType? keyboardType,
    String? Function(String?)? validator,
  }) => TextFormField(
    controller: controller,
    maxLines: maxLines,
    keyboardType: keyboardType,
    validator: validator,
    decoration: InputDecoration(labelText: label, hintText: hint),
  );

  Widget _dateField({required String label, required DateTime? value, required VoidCallback onTap, VoidCallback? onClear}) => InputDecorator(
    decoration: InputDecoration(labelText: label),
    child: Row(
      children: [
        Expanded(child: Text(value == null ? 'Not set' : _dateTimeLabel(value))),
        IconButton(onPressed: onTap, tooltip: 'Choose date and time', icon: const Icon(Icons.calendar_month_outlined)),
        if (onClear != null) IconButton(onPressed: onClear, tooltip: 'Clear date', icon: const Icon(Icons.clear_rounded)),
      ],
    ),
  );

  Widget _sectionTitle(String title, String subtitle) => Padding(
    padding: const EdgeInsets.only(top: 8, bottom: 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: AppText.heading),
        const SizedBox(height: 3),
        Text(subtitle, style: TextStyle(color: context.appMuted, fontSize: 12)),
      ],
    ),
  );

  Map<String, dynamic>? _payload() {
    if (!_formKey.currentState!.validate()) return null;
    if (_benefitType == 'free_addon' && _addOnServiceId == null) {
      AppToast.error(context, 'Choose the free add-on service');
      return null;
    }
    final code = _code.text.trim().toUpperCase();
    if (code.isEmpty && !_generateCode) {
      AppToast.error(context, 'Enter a reusable code or enable server-side code generation');
      return null;
    }
    String? optional(String value) => value.trim().isEmpty ? null : value.trim();
    return {
      if (initial['promotion_id'] != null) 'id': initial['promotion_id'],
      'name': _name.text.trim(),
      'description': _description.text.trim(),
      'benefit_type': _benefitType,
      'benefit_value': _benefitType == 'free_addon' ? '0' : _benefitValue.text.trim(),
      'usage_type': _usageType,
      'active': _active,
      'starts_at': _startsAt.toUtc().toIso8601String(),
      'ends_at': _endsAt?.toUtc().toIso8601String(),
      'max_redemptions': _usageType == 'single_use' ? '1' : optional(_maxRedemptions.text),
      'per_customer_limit': optional(_perCustomerLimit.text),
      'minimum_spend': optional(_minimumSpend.text) ?? '0',
      'maximum_discount': _benefitType == 'percentage_discount' ? optional(_maximumDiscount.text) : null,
      'online_booking_only': _onlineOnly,
      'free_addon_service_id': _benefitType == 'free_addon' ? _addOnServiceId : null,
      'free_addon_scheduling_mode': _benefitType == 'free_addon' ? _addOnMode : 'unsupported',
      'outlet_ids': _outletIds.toList(),
      'service_ids': _serviceIds.toList(),
      'code': code.isEmpty ? null : code,
      'generate_one_time_code': _generateCode,
    };
  }

  void _save() {
    final payload = _payload();
    if (payload != null) Navigator.of(context).pop(payload);
  }

  @override
  Widget build(BuildContext context) => ManagementCatalogueDetailSurface(
    title: widget.initial == null ? 'Create promotion' : 'Edit promotion',
    subtitle: 'Server-validated online booking discount',
    isFullScreen: widget.isFullScreen,
    footer: Row(
      children: [
        Expanded(
          child: OutlinedButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: FilledButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.save_outlined),
            label: const Text('Save promotion'),
          ),
        ),
      ],
    ),
    child: Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _textField(_name, 'Promotion name', hint: 'Merdeka campaign', validator: (value) => value?.trim().isEmpty == true ? 'Enter a name' : null),
          const SizedBox(height: 12),
          _textField(_description, 'Description', maxLines: 3, hint: 'Shown to staff; customers see the applied code message.'),
          _sectionTitle('Benefit', 'The server calculates the final amount; browser values are never trusted.'),
          DropdownButtonFormField<String>(
            initialValue: _benefitType,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Benefit type'),
            items: _benefits.entries.map((entry) => DropdownMenuItem(value: entry.key, child: Text(entry.value))).toList(),
            onChanged: (value) => setState(() => _benefitType = value ?? _benefitType),
          ),
          if (_benefitType != 'free_addon') ...[
            const SizedBox(height: 12),
            _textField(
              _benefitValue,
              _benefitType == 'percentage_discount' ? 'Discount percentage' : 'Discount amount (RM)',
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              validator: (value) => _amountValidator(value, percentage: _benefitType == 'percentage_discount'),
            ),
          ] else ...[
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _addOnServiceId,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Free add-on service'),
              items: widget.services.map((service) => DropdownMenuItem<String>(value: service['id'].toString(), child: Text(_serviceLabel(service)))).toList(),
              onChanged: (value) => setState(() => _addOnServiceId = value),
              validator: (value) => value == null ? 'Choose a service' : null,
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _addOnMode,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Add-on scheduling mode'),
              items: _addOnModes.entries.map((entry) => DropdownMenuItem(value: entry.key, child: Text(entry.value))).toList(),
              onChanged: (value) => setState(() => _addOnMode = value ?? _addOnMode),
            ),
          ],
          if (_benefitType == 'percentage_discount') ...[
            const SizedBox(height: 12),
            _textField(
              _maximumDiscount,
              'Maximum discount (RM)',
              hint: 'Required for percentage discounts',
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              validator: _positiveAmountValidator,
            ),
          ],
          _sectionTitle('Usage and validity', 'A single-use promotion is enforced as max_redemptions = 1.'),
          DropdownButtonFormField<String>(
            initialValue: _usageType,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Usage type'),
            items: _usageTypes.entries.map((entry) => DropdownMenuItem(value: entry.key, child: Text(entry.value))).toList(),
            onChanged: (value) => setState(() {
              _usageType = value ?? _usageType;
              if (_usageType == 'single_use') _maxRedemptions.text = '1';
              if (_usageType == 'multi_use') _generateCode = false;
            }),
          ),
          const SizedBox(height: 12),
          LayoutBuilder(builder: (context, constraints) {
            final fields = [
              _textField(_maxRedemptions, 'Total redemption limit', hint: 'Blank = unlimited', keyboardType: TextInputType.number, validator: _optionalIntegerValidator),
              _textField(_perCustomerLimit, 'Per-customer limit', hint: 'Optional', keyboardType: TextInputType.number, validator: _optionalIntegerValidator),
              _textField(_minimumSpend, 'Minimum spend (RM)', keyboardType: const TextInputType.numberWithOptions(decimal: true), validator: _amountValidator),
            ];
            if (constraints.maxWidth < 560) {
              return Column(
                children: [
                  for (var i = 0; i < fields.length; i++) ...[
                    fields[i],
                    if (i != fields.length - 1) const SizedBox(height: 12),
                  ],
                ],
              );
            }
            return Row(children: [for (var i = 0; i < fields.length; i++) ...[Expanded(child: fields[i]), if (i != fields.length - 1) const SizedBox(width: 12)]]);
          }),
          const SizedBox(height: 12),
          _dateField(
            label: 'Starts',
            value: _startsAt,
            onTap: () async {
              final value = await _pickDateTime(_startsAt);
              if (value != null) {
                setState(() => _startsAt = value);
              }
            },
          ),
          const SizedBox(height: 12),
          _dateField(
            label: 'Ends (optional)',
            value: _endsAt,
            onTap: () async {
              final value = await _pickDateTime(
                _endsAt ?? _startsAt.add(const Duration(days: 30)),
              );
              if (value != null) {
                setState(() => _endsAt = value);
              }
            },
            onClear: _endsAt == null
                ? null
                : () => setState(() => _endsAt = null),
          ),
          const SizedBox(height: 12),
          SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Enabled'), subtitle: const Text('Inactive promotions cannot be reserved.'), value: _active, onChanged: (value) => setState(() => _active = value)),
          SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Online-booking-only'), value: _onlineOnly, onChanged: (value) => setState(() => _onlineOnly = value)),
          _sectionTitle('Scope', 'No selected outlets or services means all eligible outlets or services.'),
          Text('Outlets', style: AppText.label),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: OutletContext.outlets.map((outlet) {
              return FilterChip(
                label: Text(outlet.name),
                selected: _outletIds.contains(outlet.id),
                onSelected: (selected) => setState(() {
                  if (selected) {
                    _outletIds.add(outlet.id);
                  } else {
                    _outletIds.remove(outlet.id);
                  }
                }),
              );
            }).toList(),
          ),
          const SizedBox(height: 14),
          Text('Eligible services', style: AppText.label),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilterChip(
                label: const Text('All services'),
                selected: _serviceIds.isEmpty,
                onSelected: (_) => setState(_serviceIds.clear),
              ),
              ...widget.eligibleServices.map((service) {
                final id = service['id'].toString();
                return FilterChip(
                  label: Text(_serviceLabel(service)),
                  selected: _serviceIds.contains(id),
                  onSelected: (selected) => setState(() {
                    if (selected) {
                      _serviceIds.add(id);
                    } else {
                      _serviceIds.remove(id);
                    }
                  }),
                );
              }),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            _serviceIds.isEmpty
                ? 'Applies to every enabled online-booking service.'
                : 'Applies only to the selected online-booking services.',
            style: TextStyle(color: context.appMuted, fontSize: 12),
          ),
          _sectionTitle('Code', 'Use a reusable code for a campaign, or let PostgreSQL generate a unique one-time code.'),
          _textField(_code, 'Promotion code', hint: 'MERDEKA10'),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Generate a unique code server-side'),
            subtitle: const Text('Generated codes are single-use and the database uniqueness constraint is the final authority.'),
            value: _generateCode,
            onChanged: (value) {
              setState(() {
                _generateCode = value == true;
                if (_generateCode) {
                  _usageType = 'single_use';
                  _maxRedemptions.text = '1';
                }
              });
            },
          ),
        ],
      ),
    ),
  );
}
