import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/core/accessibility/accessibility_settings.dart';
import 'package:frontend/core/theme/app_theme.dart';
import 'package:frontend/screens/management/accessibility_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('accessibility presets do not overflow supported layouts', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final controller = AccessibilityController.instance;
    await controller.initialize('accessibility-layout-test');

    final cases = <({
      Size size,
      UiScalePreset preset,
      double systemTextScale,
      String label,
    })>[
      (
        size: const Size(320, 720),
        preset: UiScalePreset.compact,
        systemTextScale: 1,
        label: 'narrow phone compact',
      ),
      (
        size: const Size(360, 800),
        preset: UiScalePreset.large,
        systemTextScale: 1.3,
        label: 'phone large',
      ),
      (
        size: const Size(600, 960),
        preset: UiScalePreset.large,
        systemTextScale: 1.6,
        label: 'small tablet large',
      ),
      (
        size: const Size(768, 1024),
        preset: UiScalePreset.standard,
        systemTextScale: 1.3,
        label: 'tablet portrait',
      ),
      (
        size: const Size(1024, 768),
        preset: UiScalePreset.large,
        systemTextScale: 1.6,
        label: 'tablet landscape large',
      ),
    ];

    for (final testCase in cases) {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = testCase.size;
      await controller.setPreset(testCase.preset);
      await controller.setFollowSystemTextScale(true);
      final metrics = UiScaleMetrics.forPreset(testCase.preset);

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(metrics),
          builder: (context, child) {
            final mediaQuery = MediaQuery.of(context);
            return MediaQuery(
              data: mediaQuery.copyWith(
                textScaler: TextScaler.linear(
                  testCase.systemTextScale * metrics.textScale,
                ),
              ),
              child: child ?? const SizedBox.shrink(),
            );
          },
          home: const AccessibilityScreen(),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        tester.takeException(),
        isNull,
        reason: testCase.label,
      );
      expect(find.text('Appearance'), findsOneWidget);
      expect(find.text('Interface size'), findsOneWidget);
      expect(find.text('Use system text size'), findsOneWidget);
    }

    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  });
}
