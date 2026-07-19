import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The tablet timetable overview wraps its schedule/zones row in an
/// [IntrinsicHeight] so the two panels match height without a hardcoded pixel
/// figure. Anything inside that row must therefore be able to report intrinsic
/// dimensions — a [LayoutBuilder] cannot, and using one there throws in debug
/// and collapses the entire overview to zero height in release (where the
/// assertion is stripped and the intrinsic silently resolves to 0).
///
/// These tests pin that contract so the zone grids are not "helpfully"
/// converted back to LayoutBuilder/Wrap measuring.
Widget _overviewRow({required Widget zoneGrid}) {
  return MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: Column(
          children: [
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: Container(
                      color: Colors.white,
                      child: const Text('In Progress'),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Container(
                      color: Colors.white,
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: [const Text('Zones'), zoneGrid],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Mirrors the shipped `flexGrid` helper in timetable_screen.dart.
Widget _flexGrid({
  required int columns,
  required double gap,
  required List<Widget> cells,
}) {
  final rows = <Widget>[];
  for (var start = 0; start < cells.length; start += columns) {
    final slice = cells.skip(start).take(columns).toList();
    rows.add(
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < columns; i++) ...[
            if (i > 0) SizedBox(width: gap),
            Expanded(
              child: i < slice.length ? slice[i] : const SizedBox.shrink(),
            ),
          ],
        ],
      ),
    );
  }
  return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      for (var i = 0; i < rows.length; i++) ...[
        if (i > 0) SizedBox(height: gap),
        rows[i],
      ],
    ],
  );
}

void main() {
  testWidgets('flex-based zone grid lays out under IntrinsicHeight', (
    tester,
  ) async {
    await tester.pumpWidget(
      _overviewRow(
        zoneGrid: _flexGrid(
          columns: 3,
          gap: 8,
          cells: [
            for (var i = 0; i < 3; i++)
              const SizedBox(height: 60, child: Text('Room')),
          ],
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Zones'), findsOneWidget);
    // The row must have real height; a collapsed overview reports 0.
    expect(tester.getSize(find.byType(IntrinsicHeight)).height, greaterThan(0));
  });

  testWidgets('odd cell counts still fill a padded final row', (tester) async {
    await tester.pumpWidget(
      _overviewRow(
        zoneGrid: _flexGrid(
          columns: 2,
          gap: 10,
          cells: [
            for (var i = 0; i < 3; i++)
              SizedBox(height: 40, child: Text('Zone $i')),
          ],
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Zone 2'), findsOneWidget);
  });

  testWidgets('a LayoutBuilder in the same position breaks layout', (
    tester,
  ) async {
    await tester.pumpWidget(
      _overviewRow(
        zoneGrid: LayoutBuilder(
          builder: (context, constraints) =>
              SizedBox(width: constraints.maxWidth / 3, height: 60),
        ),
      ),
    );

    // Documents why flexGrid exists: this is the failure mode that blanked the
    // overview. If Flutter ever supports intrinsics here, this test fails and
    // the constraint can be relaxed.
    expect(tester.takeException(), isNotNull);
  });
}
