import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum UiScalePreset { compact, standard, large }

enum AppThemePreference { system, light, dark }

extension AppThemePreferenceLabel on AppThemePreference {
  String get label => switch (this) {
    AppThemePreference.system => 'System',
    AppThemePreference.light => 'Light',
    AppThemePreference.dark => 'Dark',
  };

  ThemeMode get themeMode => switch (this) {
    AppThemePreference.system => ThemeMode.system,
    AppThemePreference.light => ThemeMode.light,
    AppThemePreference.dark => ThemeMode.dark,
  };
}

extension UiScalePresetLabel on UiScalePreset {
  String get label => switch (this) {
    UiScalePreset.compact => 'Compact',
    UiScalePreset.standard => 'Standard',
    UiScalePreset.large => 'Large',
  };

  String get description => switch (this) {
    UiScalePreset.compact => 'More information on screen',
    UiScalePreset.standard => 'Balanced text and controls',
    UiScalePreset.large => 'Larger text and touch targets',
  };
}

@immutable
class AccessibilityPreferences {
  final UiScalePreset preset;
  final bool followSystemTextScale;
  final AppThemePreference themePreference;

  const AccessibilityPreferences({
    this.preset = UiScalePreset.standard,
    this.followSystemTextScale = true,
    this.themePreference = AppThemePreference.light,
  });

  AccessibilityPreferences copyWith({
    UiScalePreset? preset,
    bool? followSystemTextScale,
    AppThemePreference? themePreference,
  }) {
    return AccessibilityPreferences(
      preset: preset ?? this.preset,
      followSystemTextScale:
          followSystemTextScale ?? this.followSystemTextScale,
      themePreference: themePreference ?? this.themePreference,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AccessibilityPreferences &&
      other.preset == preset &&
      other.followSystemTextScale == followSystemTextScale &&
      other.themePreference == themePreference;

  @override
  int get hashCode => Object.hash(
    preset,
    followSystemTextScale,
    themePreference,
  );
}

@immutable
class UiScaleMetrics extends ThemeExtension<UiScaleMetrics> {
  final UiScalePreset preset;
  final double textScale;
  final double controlHeight;
  final double fieldHeight;
  final double badgeHeight;
  final double cardPadding;
  final double appointmentScale;
  final double dashboardScale;
  final double timetableScale;
  final double navigationHeight;

  const UiScaleMetrics({
    required this.preset,
    required this.textScale,
    required this.controlHeight,
    required this.fieldHeight,
    required this.badgeHeight,
    required this.cardPadding,
    required this.appointmentScale,
    required this.dashboardScale,
    required this.timetableScale,
    required this.navigationHeight,
  });

  factory UiScaleMetrics.forPreset(UiScalePreset preset) => switch (preset) {
    UiScalePreset.compact => const UiScaleMetrics(
      preset: UiScalePreset.compact,
      textScale: 0.95,
      controlHeight: 44,
      fieldHeight: 44,
      badgeHeight: 28,
      cardPadding: 12,
      appointmentScale: 0.94,
      dashboardScale: 0.94,
      timetableScale: 0.90,
      navigationHeight: 64,
    ),
    UiScalePreset.standard => const UiScaleMetrics(
      preset: UiScalePreset.standard,
      textScale: 1,
      controlHeight: 48,
      fieldHeight: 48,
      badgeHeight: 32,
      cardPadding: 16,
      appointmentScale: 1,
      dashboardScale: 1,
      timetableScale: 1,
      navigationHeight: 68,
    ),
    UiScalePreset.large => const UiScaleMetrics(
      preset: UiScalePreset.large,
      textScale: 1.15,
      controlHeight: 56,
      fieldHeight: 56,
      badgeHeight: 36,
      cardPadding: 20,
      appointmentScale: 1.12,
      dashboardScale: 1.10,
      timetableScale: 1.18,
      navigationHeight: 76,
    ),
  };

  @override
  UiScaleMetrics copyWith({
    UiScalePreset? preset,
    double? textScale,
    double? controlHeight,
    double? fieldHeight,
    double? badgeHeight,
    double? cardPadding,
    double? appointmentScale,
    double? dashboardScale,
    double? timetableScale,
    double? navigationHeight,
  }) {
    return UiScaleMetrics(
      preset: preset ?? this.preset,
      textScale: textScale ?? this.textScale,
      controlHeight: controlHeight ?? this.controlHeight,
      fieldHeight: fieldHeight ?? this.fieldHeight,
      badgeHeight: badgeHeight ?? this.badgeHeight,
      cardPadding: cardPadding ?? this.cardPadding,
      appointmentScale: appointmentScale ?? this.appointmentScale,
      dashboardScale: dashboardScale ?? this.dashboardScale,
      timetableScale: timetableScale ?? this.timetableScale,
      navigationHeight: navigationHeight ?? this.navigationHeight,
    );
  }

  @override
  UiScaleMetrics lerp(ThemeExtension<UiScaleMetrics>? other, double t) {
    if (other is! UiScaleMetrics) return this;
    return UiScaleMetrics(
      preset: t < 0.5 ? preset : other.preset,
      textScale: _lerp(textScale, other.textScale, t),
      controlHeight: _lerp(controlHeight, other.controlHeight, t),
      fieldHeight: _lerp(fieldHeight, other.fieldHeight, t),
      badgeHeight: _lerp(badgeHeight, other.badgeHeight, t),
      cardPadding: _lerp(cardPadding, other.cardPadding, t),
      appointmentScale: _lerp(
        appointmentScale,
        other.appointmentScale,
        t,
      ),
      dashboardScale: _lerp(dashboardScale, other.dashboardScale, t),
      timetableScale: _lerp(timetableScale, other.timetableScale, t),
      navigationHeight: _lerp(
        navigationHeight,
        other.navigationHeight,
        t,
      ),
    );
  }

  static double _lerp(double a, double b, double t) => a + (b - a) * t;
}

extension AccessibilityBuildContext on BuildContext {
  UiScaleMetrics get uiScale =>
      Theme.of(this).extension<UiScaleMetrics>() ??
      UiScaleMetrics.forPreset(UiScalePreset.standard);
}

class AccessibilityController
    extends ValueNotifier<AccessibilityPreferences> {
  AccessibilityController._()
    : super(const AccessibilityPreferences());

  static final instance = AccessibilityController._();

  static const _presetKey = 'accessibility_scale_preset';
  static const _systemKey = 'accessibility_follow_system_text';
  static const _themeKey = 'accessibility_theme_preference';
  static const _browserLightDefaultMigrationKey =
      'accessibility_browser_light_default_v1';

  SharedPreferences? _storage;
  String? _userId;
  int _loadSerial = 0;

  Future<void> initialize(String? userId) async {
    _storage = await SharedPreferences.getInstance();
    await useUser(userId);
  }

  Future<void> useUser(String? userId) async {
    final normalized = userId?.trim();
    if (_storage != null && _userId == normalized && _loadSerial > 0) return;
    _userId = normalized;
    final serial = ++_loadSerial;
    final storage = _storage ?? await SharedPreferences.getInstance();
    if (serial != _loadSerial) return;
    _storage = storage;

    final presetKey = _key(_presetKey);
    final systemKey = _key(_systemKey);
    final themeKey = _key(_themeKey);
    final browserMigrationKey = _key(_browserLightDefaultMigrationKey);
    final presetName = storage.getString(presetKey);
    var themeName = storage.getString(themeKey);
    if (kIsWeb &&
        !(storage.getBool(browserMigrationKey) ?? false)) {
      if (themeName == AppThemePreference.system.name) {
        themeName = AppThemePreference.light.name;
        await storage.setString(themeKey, themeName);
      }
      await storage.setBool(browserMigrationKey, true);
    }
    if (serial != _loadSerial) return;
    final preset = UiScalePreset.values.firstWhere(
      (item) => item.name == presetName,
      orElse: () => UiScalePreset.standard,
    );
    value = AccessibilityPreferences(
      preset: preset,
      followSystemTextScale: storage.getBool(systemKey) ?? true,
      themePreference: AppThemePreference.values.firstWhere(
        (item) => item.name == themeName,
        orElse: () => AppThemePreference.light,
      ),
    );
  }

  Future<void> setPreset(UiScalePreset preset) async {
    if (value.preset == preset) return;
    value = value.copyWith(preset: preset);
    await _save();
  }

  Future<void> setFollowSystemTextScale(bool enabled) async {
    if (value.followSystemTextScale == enabled) return;
    value = value.copyWith(followSystemTextScale: enabled);
    await _save();
  }

  Future<void> setThemePreference(AppThemePreference preference) async {
    if (value.themePreference == preference) return;
    value = value.copyWith(themePreference: preference);
    await _save();
  }

  Future<void> reset() async {
    value = const AccessibilityPreferences();
    await _save();
  }

  Future<void> _save() async {
    final storage = _storage ?? await SharedPreferences.getInstance();
    _storage = storage;
    await Future.wait([
      storage.setString(_key(_presetKey), value.preset.name),
      storage.setBool(_key(_systemKey), value.followSystemTextScale),
      storage.setString(_key(_themeKey), value.themePreference.name),
    ]);
  }

  String _key(String base) => '$base:${_userId ?? 'device'}';
}
