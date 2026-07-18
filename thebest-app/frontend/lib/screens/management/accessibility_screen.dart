import 'package:flutter/material.dart';

import '../../core/accessibility/accessibility_settings.dart';
import '../../core/theme/app_theme.dart';

TextStyle _sectionTitle(BuildContext context) => Theme.of(context)
    .textTheme
    .titleLarge!
    .copyWith(fontWeight: FontWeight.w800);

TextStyle _headingStyle(BuildContext context) => Theme.of(context)
    .textTheme
    .titleMedium!
    .copyWith(fontWeight: FontWeight.w800);

TextStyle _bodyStyle(BuildContext context) =>
    Theme.of(context).textTheme.bodyMedium!;

TextStyle _captionStyle(BuildContext context) => Theme.of(context)
    .textTheme
    .bodySmall!
    .copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);

class AccessibilityScreen extends StatelessWidget {
  const AccessibilityScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = AccessibilityController.instance;
    return ValueListenableBuilder<AccessibilityPreferences>(
      valueListenable: controller,
      builder: (context, preferences, _) {
        final isDefault =
            preferences == const AccessibilityPreferences();
        return Scaffold(
          backgroundColor: Theme.of(context).scaffoldBackgroundColor,
          appBar: AppBar(
            title: const Text('Accessibility'),
            actions: [
              IconButton(
                onPressed: isDefault ? null : controller.reset,
                icon: const Icon(Icons.restart_alt_rounded),
                tooltip: 'Reset to Standard',
              ),
              const SizedBox(width: 8),
            ],
          ),
          body: LayoutBuilder(
            builder: (context, constraints) {
              final sideBySide = constraints.maxWidth >= 880;
              final pagePadding = constraints.maxWidth < 420 ? 16.0 : 24.0;
              return ListView(
                padding: EdgeInsets.fromLTRB(
                  pagePadding,
                  24,
                  pagePadding,
                  32,
                ),
                children: [
                  Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 980),
                      child: sideBySide
                          ? Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SizedBox(
                                  width: 360,
                                  child: _AccessibilitySettings(
                                    preferences: preferences,
                                    onThemeSelected:
                                        controller.setThemePreference,
                                    onPresetSelected: controller.setPreset,
                                    onSystemScaleChanged:
                                        controller.setFollowSystemTextScale,
                                  ),
                                ),
                                const SizedBox(width: 32),
                                Expanded(
                                  child: _AccessibilityPreviewSection(
                                    preset: preferences.preset,
                                  ),
                                ),
                              ],
                            )
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                _AccessibilitySettings(
                                  preferences: preferences,
                                  onThemeSelected:
                                      controller.setThemePreference,
                                  onPresetSelected: controller.setPreset,
                                  onSystemScaleChanged:
                                      controller.setFollowSystemTextScale,
                                ),
                                const SizedBox(height: 32),
                                _AccessibilityPreviewSection(
                                  preset: preferences.preset,
                                ),
                              ],
                            ),
                    ),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }
}

class _AccessibilitySettings extends StatelessWidget {
  final AccessibilityPreferences preferences;
  final ValueChanged<AppThemePreference> onThemeSelected;
  final ValueChanged<UiScalePreset> onPresetSelected;
  final ValueChanged<bool> onSystemScaleChanged;

  const _AccessibilitySettings({
    required this.preferences,
    required this.onThemeSelected,
    required this.onPresetSelected,
    required this.onSystemScaleChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Appearance', style: _sectionTitle(context)),
        const SizedBox(height: 6),
        Text(
          'Use the device theme or choose a consistent appearance.',
          style: _bodyStyle(context),
        ),
        const SizedBox(height: 14),
        _ThemeSelector(
          selected: preferences.themePreference,
          onSelected: onThemeSelected,
        ),
        const SizedBox(height: 30),
        Text('Interface size', style: _sectionTitle(context)),
        const SizedBox(height: 6),
        Text(
          'Choose how much information and control space appears on this device.',
          style: _bodyStyle(context),
        ),
        const SizedBox(height: 18),
        _PresetSelector(
          selected: preferences.preset,
          onSelected: onPresetSelected,
        ),
        const SizedBox(height: 12),
        _PresetSummary(preset: preferences.preset),
        const SizedBox(height: 30),
        Text('Text scaling', style: _sectionTitle(context)),
        const SizedBox(height: 6),
        Text(
          'Choose whether the app also follows this device\'s text-size setting.',
          style: _bodyStyle(context),
        ),
        const SizedBox(height: 14),
        _SystemFontSetting(
          value: preferences.followSystemTextScale,
          onChanged: onSystemScaleChanged,
        ),
      ],
    );
  }
}

class _ThemeSelector extends StatelessWidget {
  final AppThemePreference selected;
  final ValueChanged<AppThemePreference> onSelected;

  const _ThemeSelector({
    required this.selected,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        children: [
          for (final preference in AppThemePreference.values)
            Expanded(
              child: _ThemeSegment(
                preference: preference,
                selected: selected == preference,
                onTap: () => onSelected(preference),
              ),
            ),
        ],
      ),
    );
  }
}

class _ThemeSegment extends StatelessWidget {
  final AppThemePreference preference;
  final bool selected;
  final VoidCallback onTap;

  const _ThemeSegment({
    required this.preference,
    required this.selected,
    required this.onTap,
  });

  IconData get _icon => switch (preference) {
    AppThemePreference.system => Icons.brightness_auto_rounded,
    AppThemePreference.light => Icons.light_mode_outlined,
    AppThemePreference.dark => Icons.dark_mode_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: selected ? scheme.surface : Colors.transparent,
      borderRadius: BorderRadius.circular(6),
      elevation: selected ? 1 : 0,
      shadowColor: scheme.shadow.withValues(alpha: 0.18),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  _icon,
                  size: 17,
                  color: selected ? scheme.primary : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 5),
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      preference.label,
                      maxLines: 1,
                      style: TextStyle(
                        color: selected
                            ? scheme.primary
                            : scheme.onSurfaceVariant,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PresetSelector extends StatelessWidget {
  final UiScalePreset selected;
  final ValueChanged<UiScalePreset> onSelected;

  const _PresetSelector({
    required this.selected,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        children: [
          for (final preset in UiScalePreset.values)
            Expanded(
              child: _PresetSegment(
                preset: preset,
                selected: selected == preset,
                onTap: () => onSelected(preset),
              ),
            ),
        ],
      ),
    );
  }
}

class _PresetSegment extends StatelessWidget {
  final UiScalePreset preset;
  final bool selected;
  final VoidCallback onTap;

  const _PresetSegment({
    required this.preset,
    required this.selected,
    required this.onTap,
  });

  IconData get _icon => switch (preset) {
    UiScalePreset.compact => Icons.density_small_rounded,
    UiScalePreset.standard => Icons.view_agenda_outlined,
    UiScalePreset.large => Icons.text_increase_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: selected ? scheme.surface : Colors.transparent,
      borderRadius: BorderRadius.circular(6),
      elevation: selected ? 1 : 0,
      shadowColor: scheme.shadow.withValues(alpha: 0.18),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 64),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  _icon,
                  size: 19,
                  color: selected ? scheme.primary : scheme.onSurfaceVariant,
                ),
                const SizedBox(height: 5),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    preset.label,
                    maxLines: 1,
                    style: TextStyle(
                      color: selected
                          ? scheme.primary
                          : scheme.onSurfaceVariant,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PresetSummary extends StatelessWidget {
  final UiScalePreset preset;

  const _PresetSummary({required this.preset});

  @override
  Widget build(BuildContext context) {
    final metrics = UiScaleMetrics.forPreset(preset);
    final scheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(
            Icons.info_outline_rounded,
            size: 17,
            color: scheme.primary,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            '${preset.description}. Controls are ${metrics.controlHeight.toStringAsFixed(0)} px high.',
            style: _captionStyle(context),
          ),
        ),
      ],
    );
  }
}

class _SystemFontSetting extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;

  const _SystemFontSetting({
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      child: InkWell(
        onTap: () => onChanged(!value),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  Icons.format_size_rounded,
                  size: 20,
                  color: scheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Use system text size',
                      style: _headingStyle(context),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Recommended for device accessibility settings.',
                      style: _captionStyle(context),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Switch(value: value, onChanged: onChanged),
            ],
          ),
        ),
      ),
    );
  }
}

class _AccessibilityPreviewSection extends StatelessWidget {
  final UiScalePreset preset;

  const _AccessibilityPreviewSection({required this.preset});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text('Live preview', style: _sectionTitle(context)),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                borderRadius: BorderRadius.circular(AppRadius.pill),
              ),
              child: Text(
                preset.label,
                style: TextStyle(
                  color: scheme.onPrimaryContainer,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          'Text, fields, badges, cards, and actions update immediately.',
          style: _bodyStyle(context),
        ),
        const SizedBox(height: 14),
        const _AccessibilityPreview(),
      ],
    );
  }
}

class _AccessibilityPreview extends StatelessWidget {
  const _AccessibilityPreview();

  @override
  Widget build(BuildContext context) {
    final metrics = context.uiScale;
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      child: Padding(
        padding: EdgeInsets.all(metrics.cardPadding),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _PreviewAppointmentHeader(),
            const SizedBox(height: 16),
            const Divider(height: 1),
            const SizedBox(height: 14),
            LayoutBuilder(
              builder: (context, constraints) {
                final stack = constraints.maxWidth < 430;
                final note = SizedBox(
                  height: metrics.fieldHeight,
                  child: const TextField(
                    decoration: InputDecoration(
                      hintText: 'Customer note',
                      prefixIcon: Icon(Icons.notes_rounded),
                    ),
                  ),
                );
                final action = SizedBox(
                  height: metrics.controlHeight,
                  child: FilledButton.icon(
                    onPressed: () {},
                    icon: const Icon(Icons.login_rounded),
                    label: const Text('Check In'),
                  ),
                );
                if (stack) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      note,
                      const SizedBox(height: 10),
                      action,
                    ],
                  );
                }
                return Row(
                  children: [
                    Expanded(child: note),
                    const SizedBox(width: 10),
                    action,
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _PreviewAppointmentHeader extends StatelessWidget {
  const _PreviewAppointmentHeader();

  @override
  Widget build(BuildContext context) {
    final metrics = context.uiScale;
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final success = dark ? const Color(0xFF73D99A) : AppColors.success;
    final successSoft = dark
        ? const Color(0xFF173D2A)
        : AppColors.successSoft;
    final status = Container(
      constraints: BoxConstraints(minHeight: metrics.badgeHeight),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: successSoft,
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Text(
        'Confirmed',
        style: TextStyle(
          color: success,
          fontSize: 11,
          fontWeight: FontWeight.w800,
        ),
      ),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 360;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 44,
              height: 44,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '1',
                style: TextStyle(
                  color: scheme.onPrimaryContainer,
                  fontSize: 17,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (narrow) ...[
                    Align(alignment: Alignment.centerLeft, child: status),
                    const SizedBox(height: 8),
                  ],
                  Text('Foot Massage', style: _headingStyle(context)),
                  const SizedBox(height: 3),
                  Text(
                    'Hung - 10:30 to 11:30',
                    style: _bodyStyle(context),
                  ),
                  const SizedBox(height: 6),
                  const Wrap(
                    spacing: 10,
                    runSpacing: 5,
                    children: [
                      _PreviewMeta(
                        icon: Icons.person_outline,
                        label: 'Alex (1)',
                      ),
                      _PreviewMeta(
                        icon: Icons.meeting_room_outlined,
                        label: 'Upper Floor Foot Zone',
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (!narrow) ...[
              const SizedBox(width: 8),
              status,
            ],
          ],
        );
      },
    );
  }
}

class _PreviewMeta extends StatelessWidget {
  final IconData icon;
  final String label;

  const _PreviewMeta({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: scheme.onSurfaceVariant),
        const SizedBox(width: 4),
        Text(label, style: _captionStyle(context)),
      ],
    );
  }
}
