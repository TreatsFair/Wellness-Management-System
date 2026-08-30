import 'package:flutter/foundation.dart';

/// Process-local invalidation for views that render live therapist capacity.
///
/// Availability-changing actions are committed by the backend before their
/// initiating screen reloads. Retained routes still need an immediate signal
/// so they do not wait for their periodic refresh timers or a hard reload.
class TherapistAvailabilityRefresh {
  TherapistAvailabilityRefresh._();

  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  static void notifyChanged() {
    revision.value += 1;
  }
}
