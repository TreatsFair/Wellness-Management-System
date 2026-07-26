import 'package:flutter/material.dart';

import '../../core/outlets/outlet_context.dart';
import '../../core/theme/app_theme.dart';
import '../../data/repositories/business_settings_repository.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/management_catalogue_shell.dart';

enum _BusinessSection { outlet, tax, attendance }

class BusinessSettingsScreen extends StatefulWidget {
  const BusinessSettingsScreen({super.key});

  @override
  State<BusinessSettingsScreen> createState() => _BusinessSettingsScreenState();
}

class _BusinessSettingsScreenState extends State<BusinessSettingsScreen> {
  final _repository = BusinessSettingsRepository();
  final _formKey = GlobalKey<FormState>();
  final _sstRate = TextEditingController();
  final _lateGrace = TextEditingController();
  final _noShowThreshold = TextEditingController();
  final _delayWarning = TextEditingController();

  _BusinessSection _section = _BusinessSection.outlet;
  String _settingsId = '';
  String _billplzSstMode = 'inclusive';
  String _counterSstMode = 'exclusive';
  String _roundingMode = 'nearest_cent';
  bool _sstEnabled = true;
  bool _autoExtend = false;
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _sstRate.dispose();
    _lateGrace.dispose();
    _noShowThreshold.dispose();
    _delayWarning.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    try {
      final row = await _repository.getActiveSettingsRow();
      final settings = row == null
          ? BusinessRuleSettings.defaults()
          : BusinessRuleSettings.fromMap(row);
      if (!mounted) return;
      setState(() {
        _settingsId = row?['id']?.toString() ?? '';
        _sstEnabled = settings.sstEnabled;
        _billplzSstMode = settings.billplzSstPricingMode;
        _counterSstMode = settings.counterSstPricingMode;
        _roundingMode = settings.sstRoundingMode;
        _autoExtend = settings.autoExtendLateArrivals;
        _sstRate.text = settings.sstRatePercent.toStringAsFixed(
          settings.sstRatePercent % 1 == 0 ? 0 : 2,
        );
        _lateGrace.text = settings.lateGraceMinutes.toString();
        _noShowThreshold.text = settings.noShowThresholdMinutes.toString();
        _delayWarning.text = settings.delayWarningMinutes.toString();
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      AppToast.error(context, 'Unable to load business settings: $error');
    }
  }

  Future<void> _save() async {
    if (_saving || _formKey.currentState?.validate() != true) return;
    setState(() => _saving = true);
    try {
      await _repository.saveActiveSettings({
        'sstEnabled': _sstEnabled,
        'billplzSstPricingMode': _billplzSstMode,
        'counterSstPricingMode': _counterSstMode,
        'sstRatePercent': double.tryParse(_sstRate.text.trim()) ?? 0,
        'sstRoundingMode': _roundingMode,
        'lateGraceMinutes': int.tryParse(_lateGrace.text.trim()) ?? 0,
        'noShowThresholdMinutes':
            int.tryParse(_noShowThreshold.text.trim()) ?? 0,
        'autoExtendLateArrivals': _autoExtend,
        'delayWarningMinutes': int.tryParse(_delayWarning.text.trim()) ?? 0,
      }, id: _settingsId);
      if (!mounted) return;
      AppToast.success(context, 'Business settings updated');
      await _load();
    } catch (error) {
      if (!mounted) return;
      AppToast.error(context, 'Unable to save business settings: $error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final outlet = OutletContext.activeOutlet;
    final title = switch (_section) {
      _BusinessSection.outlet => 'Outlet overview',
      _BusinessSection.tax => 'Tax & pricing',
      _BusinessSection.attendance => 'Attendance rules',
    };
    final subtitle = switch (_section) {
      _BusinessSection.outlet => 'Settings apply to ${outlet.name}',
      _BusinessSection.tax => 'SST calculation and rounding',
      _BusinessSection.attendance => 'Late arrival and no-show handling',
    };

    return ManagementCatalogueShell(
      moduleTitle: 'Business Settings',
      moduleSubtitle: 'Outlet financial and attendance rules',
      contentTitle: title,
      itemCountLabel: subtitle,
      primaryAction: CataloguePrimaryButton(
        icon: Icons.save_outlined,
        label: 'Save Settings',
        busy: _saving,
        onPressed: _loading ? null : _save,
      ),
      navigation: _navigation(),
      mobileNavigation: _mobileNavigation(),
      content: _loading
          ? const Center(child: CircularProgressIndicator())
          : Form(
              key: _formKey,
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 980),
                      child: switch (_section) {
                        _BusinessSection.outlet => _outletSection(outlet.name),
                        _BusinessSection.tax => _taxSection(),
                        _BusinessSection.attendance => _attendanceSection(),
                      },
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _navigation() => ListView(
    padding: const EdgeInsets.all(12),
    children: [
      _navigationTile(
        section: _BusinessSection.outlet,
        icon: Icons.storefront_outlined,
        title: 'Outlet overview',
        subtitle: 'Current outlet and scope',
      ),
      _navigationTile(
        section: _BusinessSection.tax,
        icon: Icons.receipt_long_outlined,
        title: 'Tax & pricing',
        subtitle: 'SST mode, rate and rounding',
      ),
      _navigationTile(
        section: _BusinessSection.attendance,
        icon: Icons.schedule_outlined,
        title: 'Attendance rules',
        subtitle: 'Late arrivals and no-shows',
      ),
    ],
  );

  Widget _navigationTile({
    required _BusinessSection section,
    required IconData icon,
    required String title,
    required String subtitle,
  }) => CatalogueSidebarTile(
    icon: icon,
    title: title,
    subtitle: subtitle,
    count: null,
    selected: _section == section,
    onTap: () => setState(() => _section = section),
  );

  Widget _mobileNavigation() => CatalogueMobileNavigation(
    children: [
      for (final section in _BusinessSection.values)
        CatalogueNavigationChip(
          label: switch (section) {
            _BusinessSection.outlet => 'Outlet',
            _BusinessSection.tax => 'Tax & pricing',
            _BusinessSection.attendance => 'Attendance',
          },
          selected: _section == section,
          onTap: () => setState(() => _section = section),
        ),
    ],
  );

  Widget _outletSection(String outletName) => _SettingsCard(
    icon: Icons.storefront_outlined,
    title: 'Current outlet',
    subtitle: 'These rules are stored separately for each outlet.',
    child: _SummaryRow(
      icon: Icons.location_on_outlined,
      title: outletName,
      subtitle: 'Change outlet from the Dashboard',
      badge: 'Active outlet',
    ),
  );

  Widget _taxSection() => _SettingsCard(
    icon: Icons.receipt_long_outlined,
    title: 'SST configuration',
    subtitle: 'Controls how tax is calculated and shown at checkout.',
    child: Column(
      children: [
        _SettingsSwitch(
          title: 'SST enabled',
          subtitle: 'Apply SST to service pricing for this outlet',
          value: _sstEnabled,
          onChanged: _saving
              ? null
              : (value) => setState(() => _sstEnabled = value),
        ),
        const SizedBox(height: 16),
        LayoutBuilder(
          builder: (context, constraints) {
            final stack = constraints.maxWidth < 720;
            final fields = [
              DropdownButtonFormField<String>(
                initialValue: _billplzSstMode,
                isExpanded: true,
                items: const [
                  DropdownMenuItem(
                    value: 'inclusive',
                    child: Text('Inclusive'),
                  ),
                  DropdownMenuItem(
                    value: 'exclusive',
                    child: Text('Exclusive'),
                  ),
                ],
                onChanged: _saving
                    ? null
                    : (value) =>
                          setState(() => _billplzSstMode = value ?? 'inclusive'),
                decoration: _decoration('Billplz payments'),
              ),
              DropdownButtonFormField<String>(
                initialValue: _counterSstMode,
                isExpanded: true,
                items: const [
                  DropdownMenuItem(
                    value: 'inclusive',
                    child: Text('Inclusive (nett)'),
                  ),
                  DropdownMenuItem(
                    value: 'exclusive',
                    child: Text('Exclusive (+ SST)'),
                  ),
                ],
                onChanged: _saving
                    ? null
                    : (value) => setState(
                        () => _counterSstMode = value ?? 'exclusive',
                      ),
                decoration: _decoration('Counter payments'),
              ),
              _numberField(
                controller: _sstRate,
                label: 'SST percentage',
                suffix: '%',
                max: 100,
              ),
              DropdownButtonFormField<String>(
                initialValue: _roundingMode,
                isExpanded: true,
                items: const [
                  DropdownMenuItem(
                    value: 'nearest_cent',
                    child: Text('Nearest cent'),
                  ),
                  DropdownMenuItem(
                    value: 'nearest_10_sen',
                    child: Text('Nearest 10 sen'),
                  ),
                  DropdownMenuItem(
                    value: 'nearest_5_sen',
                    child: Text('Nearest 5 sen'),
                  ),
                  DropdownMenuItem(
                    value: 'floor_cent',
                    child: Text('Round down'),
                  ),
                  DropdownMenuItem(value: 'ceil_cent', child: Text('Round up')),
                ],
                onChanged: _saving
                    ? null
                    : (value) => setState(
                        () => _roundingMode = value ?? 'nearest_cent',
                      ),
                decoration: _decoration('Rounding'),
              ),
            ];
            if (stack) {
              return Column(
                children: [
                  for (var i = 0; i < fields.length; i++) ...[
                    fields[i],
                    if (i != fields.length - 1) const SizedBox(height: 12),
                  ],
                ],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < fields.length; i++) ...[
                  Expanded(child: fields[i]),
                  if (i != fields.length - 1) const SizedBox(width: 12),
                ],
              ],
            );
          },
        ),
      ],
    ),
  );

  Widget _attendanceSection() => _SettingsCard(
    icon: Icons.schedule_outlined,
    title: 'Late arrival handling',
    subtitle: 'Clear thresholds keep counter and therapist decisions aligned.',
    child: Column(
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final stack = constraints.maxWidth < 720;
            final fields = [
              _numberField(
                controller: _lateGrace,
                label: 'Grace period',
                suffix: 'min',
                max: 240,
              ),
              _numberField(
                controller: _noShowThreshold,
                label: 'No-show threshold',
                suffix: 'min',
                max: 480,
              ),
              _numberField(
                controller: _delayWarning,
                label: 'Delay warning',
                suffix: 'min',
                max: 240,
              ),
            ];
            if (stack) {
              return Column(
                children: [
                  for (var i = 0; i < fields.length; i++) ...[
                    fields[i],
                    if (i != fields.length - 1) const SizedBox(height: 12),
                  ],
                ],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < fields.length; i++) ...[
                  Expanded(child: fields[i]),
                  if (i != fields.length - 1) const SizedBox(width: 12),
                ],
              ],
            );
          },
        ),
        const SizedBox(height: 16),
        _SettingsSwitch(
          title: 'Auto-extend late arrivals',
          subtitle: 'Extend the expected end when operational rules allow it',
          value: _autoExtend,
          onChanged: _saving
              ? null
              : (value) => setState(() => _autoExtend = value),
        ),
      ],
    ),
  );

  TextFormField _numberField({
    required TextEditingController controller,
    required String label,
    required String suffix,
    required int max,
  }) => TextFormField(
    controller: controller,
    enabled: !_saving,
    keyboardType: const TextInputType.numberWithOptions(decimal: true),
    autovalidateMode: AutovalidateMode.onUserInteraction,
    decoration: _decoration(label).copyWith(suffixText: suffix),
    validator: (value) {
      final parsed = double.tryParse(value?.trim() ?? '');
      if (parsed == null) return 'Enter a number';
      if (parsed < 0 || parsed > max) return '0 to $max';
      return null;
    },
  );

  InputDecoration _decoration(String label) => InputDecoration(
    labelText: label,
    filled: true,
    fillColor: context.appCanvas,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: BorderSide(color: context.appBorder),
    ),
  );
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: context.appSurface,
      border: Border.all(color: context.appBorder),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: context.appColors.primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Icon(icon, color: context.appColors.primary, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: context.appText,
                      fontSize: 17,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(subtitle, style: TextStyle(color: context.appMuted)),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        child,
      ],
    ),
  );
}

class _SettingsSwitch extends StatelessWidget {
  const _SettingsSwitch({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
    decoration: BoxDecoration(
      color: context.appCanvas,
      border: Border.all(color: context.appBorder),
      borderRadius: BorderRadius.circular(9),
    ),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  color: context.appText,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: TextStyle(color: context.appMuted, fontSize: 12),
              ),
            ],
          ),
        ),
        Switch(value: value, onChanged: onChanged),
      ],
    ),
  );
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.badge,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String badge;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: context.appCanvas,
      border: Border.all(color: context.appBorder),
      borderRadius: BorderRadius.circular(9),
    ),
    child: Row(
      children: [
        Icon(icon, color: context.appColors.primary),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  color: context.appText,
                  fontWeight: FontWeight.w900,
                ),
              ),
              Text(
                subtitle,
                style: TextStyle(color: context.appMuted, fontSize: 12),
              ),
            ],
          ),
        ),
        const SizedBox(width: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
          decoration: BoxDecoration(
            color: context.appColors.primary.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            badge,
            style: TextStyle(
              color: context.appColors.primary,
              fontSize: 11,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ],
    ),
  );
}
