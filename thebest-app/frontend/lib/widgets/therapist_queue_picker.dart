import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/services/csp_service.dart';
import '../core/utils/staff_initials.dart';
import '../data/services/supabase_table_service.dart';

typedef TherapistPreferenceChanged =
    void Function(String assignmentSource, String? requestedGender);

/// What the picker resolved: who was picked, and why -- feeds directly into
/// assignment_source/requested_gender on the appointment/walk-in row.
class TherapistAssignmentPick {
  const TherapistAssignmentPick({
    required this.therapistId,
    required this.therapistName,
    required this.assignmentSource,
    this.requestedGender,
  });

  final String therapistId;
  final String therapistName;
  final String assignmentSource;
  final String? requestedGender;
}

/// Shared therapist-selection UI for the live running queue -- used
/// identically by the walk-in flow, the counter appointment booking flow,
/// and the appointment check-in flow. Shows free-first live queue order, a
/// lightly highlighted up-next row, and a gender preference filter. Queue
/// order recommends a therapist; direct row taps are counter choices.
class TherapistQueuePicker extends StatefulWidget {
  const TherapistQueuePicker({
    super.key,
    required this.outletId,
    required this.date,
    required this.startTime,
    required this.durationMinutes,
    required this.onSelected,
    this.excludedTherapistIds = const {},
    this.eligibleTherapistIds,
    this.selectedTherapistId,
    this.initialRequestedGender,
    this.initialAssignmentSource = 'queue',
    this.followLiveClock = true,
    this.compactAssignment = false,
    this.allowFutureReservation = false,
    this.onPreferenceChanged,
    this.emptyLabel = 'No therapists available for this outlet.',
  });

  final String outletId;
  final String date;
  final String startTime;
  final int durationMinutes;
  final Set<String> excludedTherapistIds;
  final Set<String>? eligibleTherapistIds;
  final String? selectedTherapistId;
  final String? initialRequestedGender;
  final String initialAssignmentSource;
  final bool followLiveClock;
  final bool compactAssignment;
  final bool allowFutureReservation;
  final String emptyLabel;
  final ValueChanged<TherapistAssignmentPick> onSelected;
  final TherapistPreferenceChanged? onPreferenceChanged;

  @override
  State<TherapistQueuePicker> createState() => TherapistQueuePickerState();
}

class TherapistQueuePickerState extends State<TherapistQueuePicker> {
  // Keep the former hard queue-turn confirmation available for a later policy
  // change, but disable it for the concrete-locking MVP.
  static const bool _hardQueueTurnRestrictionEnabled = false;

  List<TherapistQueueEntry> _entries = [];
  bool _loading = true;
  String? _error;
  String? _genderFilter;
  late String _assignmentSource;
  QueueScheduleStatus? _scheduleStatus;
  Timer? _refreshTimer;
  Map<String, String> _profileImages = const {};

  @override
  void initState() {
    super.initState();
    _assignmentSource = widget.initialAssignmentSource;
    _genderFilter = _normalizedGender(widget.initialRequestedGender);
    _load();
    _refreshTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => unawaited(_load(showLoading: false)),
    );
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant TherapistQueuePicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Live call sites pass
    // `DateFormat('HH:mm:ss').format(DateTime.now())`, which changes on every
    // parent rebuild (each second, and on any setState such as selecting a
    // therapist or a gender chip). Reloading on that churn caused a full
    // get_therapist_queue round-trip + list flicker on every tap. The live
    // reference time is only relevant when the window actually changes. In
    // appointment-edit mode followLiveClock is false, so startTime is a stable
    // scheduled time and must trigger a reload when edited. The 30-second timer
    // supplies a fresh clock only for live mode; use `refresh()` explicitly.
    if (oldWidget.initialRequestedGender != widget.initialRequestedGender) {
      _genderFilter = _normalizedGender(widget.initialRequestedGender);
    }
    if (oldWidget.initialAssignmentSource != widget.initialAssignmentSource) {
      _assignmentSource = widget.initialAssignmentSource;
      _genderFilter = _assignmentSource == 'gender_preference'
          ? _normalizedGender(widget.initialRequestedGender)
          : null;
    }
    if (oldWidget.outletId != widget.outletId ||
        oldWidget.date != widget.date ||
        oldWidget.durationMinutes != widget.durationMinutes ||
        oldWidget.followLiveClock != widget.followLiveClock ||
        (!widget.followLiveClock &&
            oldWidget.startTime != widget.startTime)) {
      _load();
    }
  }

  static String? _normalizedGender(String? value) {
    final normalized = value?.trim().toLowerCase();
    if (normalized == 'female' || normalized == 'f') return 'female';
    if (normalized == 'male' || normalized == 'm') return 'male';
    return null;
  }

  Future<void> _load({bool showLoading = true}) async {
    if (showLoading) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final entries = await CspService.getTherapistQueue(
        outletId: widget.outletId,
        date: widget.date,
        nowTime: widget.followLiveClock && !showLoading
            ? DateFormat('HH:mm:ss').format(DateTime.now())
            : widget.startTime,
        duration: widget.durationMinutes,
      );
      // Only when the queue is empty do we need the diagnostic to explain why
      // (nobody scheduled vs. schedules not configured) -- avoids a second
      // round-trip on the common, non-empty path.
      QueueScheduleStatus? status;
      if (entries.isEmpty) {
        try {
          status = await CspService.getQueueScheduleStatus(
            outletId: widget.outletId,
            date: widget.date,
          );
        } catch (_) {
          status = null;
        }
      }
      var profileImages = _profileImages;
      try {
        final therapistRows = await SupabaseTableService(
          'therapists',
        ).getManyByIds(entries.map((entry) => entry.therapistId));
        profileImages = {
          for (final row in therapistRows)
            row['id']?.toString() ?? '':
                row['profileImageUrl']?.toString() ??
                row['imageUrl']?.toString() ??
                '',
        }..remove('');
      } catch (_) {
        // Queue selection remains usable if profile media cannot be loaded.
      }
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _profileImages = profileImages;
        _scheduleStatus = status;
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      if (showLoading || _entries.isEmpty) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      } else {
        debugPrint('Unable to silently refresh therapist queue: $e');
      }
    }
  }

  Future<void> refresh() => _load();

  void _selectCompactPreference(String source, String? gender) {
    setState(() {
      _assignmentSource = source;
      _genderFilter = _normalizedGender(gender);
    });
    widget.onPreferenceChanged?.call(
      source,
      _genderFilter == null ? null : _genderFilterLabel,
    );
  }

  /// Explains an empty list so staff can tell a genuine day off from missing
  /// setup. When the queue itself is empty the diagnostic drives the wording;
  /// when only the gender filter emptied it, that's called out instead.
  String _emptyMessage() {
    if (_entries.isNotEmpty && _genderFilter != null) {
      return 'No ${_genderFilterLabel.toLowerCase()} therapist is available right now.';
    }
    final status = _scheduleStatus;
    if (status == null) return widget.emptyLabel;
    if (status.activeCount == 0) {
      return 'No therapists are set up for this outlet.';
    }
    if (status.scheduledCount == 0) {
      return status.unscheduledActiveCount > 0
          ? 'Staff schedules aren’t set up yet — add therapist working '
                'hours so the queue can be built.'
          : 'No therapists are scheduled to work today.';
    }
    return 'All scheduled therapists are off-shift or busy right now.';
  }

  String get _genderFilterLabel => switch (_genderFilter) {
    'female' => 'Female',
    'male' => 'Male',
    _ => 'All',
  };

  bool _matchesGender(TherapistQueueEntry entry) {
    final filter = _genderFilter;
    if (filter == null) return true;
    final gender = entry.gender.trim().toLowerCase();
    return gender == filter ||
        (filter == 'female' && gender == 'f') ||
        (filter == 'male' && gender == 'm');
  }

  List<TherapistQueueEntry> get _filtered => _entries
      .where(_matchesGender)
      .toList();

  bool _isSelectable(TherapistQueueEntry entry) {
    final eligibleIds = widget.eligibleTherapistIds;
    return (entry.isFreeNow || widget.allowFutureReservation) &&
        !widget.excludedTherapistIds.contains(entry.therapistId) &&
        (eligibleIds == null || eligibleIds.contains(entry.therapistId));
  }

  List<TherapistQueueEntry> get _orderedFiltered {
    final ordered = [..._filtered];
    final rankById = <String, int>{
      for (var index = 0; index < ordered.length; index++)
        ordered[index].therapistId: index,
    };
    final upNextId = _contextualUpNext?.therapistId;
    ordered.sort((left, right) {
      final leftIsNext = left.therapistId == upNextId;
      final rightIsNext = right.therapistId == upNextId;
      if (leftIsNext != rightIsNext) return leftIsNext ? -1 : 1;
      if (left.isFreeNow != right.isFreeNow) return left.isFreeNow ? -1 : 1;
      return (rankById[left.therapistId] ?? 9999).compareTo(
        rankById[right.therapistId] ?? 9999,
      );
    });
    return ordered;
  }

  /// The up-next pick within the active filter: first free-now in live
  /// rotation order after gender and already-used therapists are considered.
  TherapistQueueEntry? get _contextualUpNext {
    final freeNow = _filtered.where(_isSelectable).toList();
    if (freeNow.isEmpty) return null;
    final actuallyFree = freeNow.where((entry) => entry.isFreeNow);
    return actuallyFree.isNotEmpty ? actuallyFree.first : freeNow.first;
  }

  Future<void> _handleTap(TherapistQueueEntry entry) async {
    if (!_isSelectable(entry)) return;

    // Tapping the therapist the queue already recommends is not an override —
    // it keeps the automatic source. Anyone else is a counter choice, which in
    // the concrete-locking MVP is allowed outright (manual_override) rather
    // than gated on a queue-turn confirmation.
    final upNext = _contextualUpNext;
    if (upNext?.therapistId == entry.therapistId) {
      widget.onSelected(
        TherapistAssignmentPick(
          therapistId: entry.therapistId,
          therapistName: entry.name,
          assignmentSource: _genderFilter == null ? 'queue' : 'gender_preference',
          requestedGender: _genderFilter == null ? null : _genderFilterLabel,
        ),
      );
      return;
    }

    final reason = _hardQueueTurnRestrictionEnabled
        ? await _showOutOfOrderDialog(entry)
        : 'manual_override';
    if (reason == null || !mounted) return;
    widget.onSelected(
      TherapistAssignmentPick(
        therapistId: entry.therapistId,
        therapistName: entry.name,
        assignmentSource: reason,
        requestedGender: _genderFilter == null ? null : _genderFilterLabel,
      ),
    );
  }

  Widget _buildCompactPicker(List<TherapistQueueEntry> filtered) {
    final selectable = filtered.where(_isSelectable).toList();
    final preservedMatches = _entries.where(
      (entry) => entry.therapistId == widget.selectedTherapistId,
    );
    final preservesNamedRequest =
        (_assignmentSource == 'specific_customer_request' ||
            _assignmentSource == 'manual_override') &&
        widget.selectedTherapistId != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Therapist preference',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: Color(0xFF475569),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _PreferenceChip(
              label: 'Next in queue',
              isSelected: _assignmentSource == 'queue',
              onTap: () => _selectCompactPreference('queue', null),
            ),
            _PreferenceChip(
              label: 'Female',
              isSelected:
                  _assignmentSource == 'gender_preference' &&
                  _genderFilter == 'female',
              onTap: () =>
                  _selectCompactPreference('gender_preference', 'Female'),
            ),
            _PreferenceChip(
              label: 'Male',
              isSelected:
                  _assignmentSource == 'gender_preference' &&
                  _genderFilter == 'male',
              onTap: () =>
                  _selectCompactPreference('gender_preference', 'Male'),
            ),
          ],
        ),
        if (preservesNamedRequest) ...[
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFFF5F3FF),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFFDDD6FE)),
            ),
            child: Text(
              'Customer request preserved: ${preservedMatches.isEmpty ? 'Current therapist' : preservedMatches.first.name}',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: Color(0xFF6D28D9),
              ),
            ),
          ),
        ],
        const SizedBox(height: 12),
        if (_assignmentSource == 'queue')
          const _AutoAssignmentPreview(
            label:
                'The next eligible therapist is auto assigned from the live queue and locked when the appointment is saved.',
          )
        else if (_assignmentSource == 'gender_preference') ...[
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFE2E8F0)),
            ),
            child: Theme(
              data: Theme.of(context).copyWith(
                dividerColor: Colors.transparent,
              ),
              child: ExpansionTile(
                initiallyExpanded: true,
                maintainState: true,
                tilePadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 2,
                ),
                childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                leading: Icon(
                  _genderFilter == 'female'
                      ? Icons.female_rounded
                      : Icons.male_rounded,
                  color: _genderFilter == 'female'
                      ? const Color(0xFFBE185D)
                      : const Color(0xFF2563EB),
                ),
                title: Text(
                  '$_genderFilterLabel therapists',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w900,
                    color: Color(0xFF1A1A2E),
                  ),
                ),
                subtitle: Text(
                  selectable.isEmpty
                      ? 'No matching therapist in the live queue'
                      : '${selectable.length} in the current live queue',
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: Color(0xFF64748B),
                  ),
                ),
                children: selectable.isEmpty
                    ? [
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              _emptyMessage(),
                              style: const TextStyle(
                                fontSize: 12,
                                color: Color(0xFFB45309),
                              ),
                            ),
                          ),
                        ),
                      ]
                    : [
                        for (final entry in selectable)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: _QueueRow(
                              entry: entry,
                              profileImageUrl:
                                  _profileImages[entry.therapistId] ?? '',
                              isSelected:
                                  widget.selectedTherapistId ==
                                  entry.therapistId,
                              isDisabled: false,
                              emphasized:
                                  entry.therapistId ==
                                  _contextualUpNext?.therapistId,
                              onTap: () => _handleTap(entry),
                            ),
                          ),
                      ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Leave the list unselected to auto assign the next eligible $_genderFilterLabel therapist when the appointment is saved.',
            style: const TextStyle(
              fontSize: 11.5,
              color: Color(0xFF64748B),
            ),
          ),
        ],
      ],
    );
  }

  Future<String?> _showOutOfOrderDialog(TherapistQueueEntry entry) {
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => _OutOfOrderQueueDialog(entry: entry),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            const Expanded(
              child: Text(
                'Unable to load the therapist queue.',
                style: TextStyle(fontSize: 13, color: Color(0xFFB91C1C)),
              ),
            ),
            TextButton(onPressed: _load, child: const Text('Retry')),
          ],
        ),
      );
    }

    final filtered = _orderedFiltered;
    if (widget.compactAssignment) {
      return _buildCompactPicker(filtered);
    }
    final upNext = _contextualUpNext;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Therapist preference',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: Color(0xFF6B7280),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _PreferenceChip(
              label: 'All',
              isSelected: _genderFilter == null,
              onTap: () => setState(() => _genderFilter = null),
            ),
            _PreferenceChip(
              label: 'Female',
              isSelected: _genderFilter == 'female',
              onTap: () => setState(() => _genderFilter = 'female'),
            ),
            _PreferenceChip(
              label: 'Male',
              isSelected: _genderFilter == 'male',
              onTap: () => setState(() => _genderFilter = 'male'),
            ),
          ],
        ),
        const SizedBox(height: 18),
        const Divider(height: 1, color: Color(0xFFE5E7EB)),
        const SizedBox(height: 14),
        const Row(
          children: [
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      'Live running queue',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF1A1A2E),
                      ),
                    ),
                  ),
                  SizedBox(width: 7),
                  Tooltip(
                    message: 'The queue follows live therapist rotation.',
                    child: Icon(
                      Icons.info_outline,
                      size: 15,
                      color: Color(0xFF64748B),
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(width: 10),
            _AutoUpdateIndicator(),
          ],
        ),
        const SizedBox(height: 10),
        if (filtered.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              _emptyMessage(),
              style: const TextStyle(fontSize: 13, color: Color(0xFF9E9E9E)),
            ),
          )
        else ...[
          ...filtered.map((entry) {
            final isDisabled = !_isSelectable(entry);
            final isSelected = widget.selectedTherapistId == entry.therapistId;
            final isUpNext = upNext?.therapistId == entry.therapistId;
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _QueueRow(
                entry: entry,
                profileImageUrl: _profileImages[entry.therapistId] ?? '',
                isSelected: isSelected,
                isDisabled: isDisabled,
                emphasized: isUpNext,
                onTap: isDisabled ? null : () => _handleTap(entry),
              ),
            );
          }),
        ],
      ],
    );
  }
}

class _OutOfOrderQueueDialog extends StatelessWidget {
  const _OutOfOrderQueueDialog({required this.entry});

  final TherapistQueueEntry entry;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 24, 28, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 64,
                    height: 64,
                    decoration: const BoxDecoration(
                      color: Color(0xFFEAF5F5),
                      shape: BoxShape.circle,
                    ),
                    child: const Stack(
                      alignment: Alignment.center,
                      children: [
                        Icon(
                          Icons.groups_2_outlined,
                          size: 34,
                          color: Color(0xFF1B6B72),
                        ),
                        Positioned(
                          right: 7,
                          bottom: 7,
                          child: Icon(
                            Icons.warning_amber_rounded,
                            size: 22,
                            color: Color(0xFFD97706),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 18),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 9),
                      child: Text(
                        '${entry.name} is not next in queue',
                        style: const TextStyle(
                          fontSize: 23,
                          height: 1.2,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF16252A),
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              const Text(
                'This therapist is out of the running queue order. Why is this selection being made?',
                style: TextStyle(
                  fontSize: 16,
                  height: 1.55,
                  color: Color(0xFF64748B),
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Customer requested records a specific request. Counter override records a staff choice outside queue order. Both consume a normal turn only when service starts.',
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.45,
                  color: Color(0xFF64748B),
                ),
              ),
              const SizedBox(height: 24),
              const Divider(height: 1, color: Color(0xFFE2E8F0)),
              const SizedBox(height: 20),
              LayoutBuilder(
                builder: (context, constraints) {
                  final stackButtons = constraints.maxWidth < 520;
                  final buttons = <Widget>[
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Cancel'),
                    ),
                    OutlinedButton(
                      onPressed: () =>
                          Navigator.pop(context, 'manual_override'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF1B6B72),
                        side: const BorderSide(color: Color(0xFF1B6B72)),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 22,
                          vertical: 15,
                        ),
                      ),
                      child: const Text('Counter override'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(
                        context,
                        'specific_customer_request',
                      ),
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF1B6B72),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 22,
                          vertical: 15,
                        ),
                      ),
                      child: const Text('Customer requested'),
                    ),
                  ];
                  if (stackButtons) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (var i = 0; i < buttons.length; i++) ...[
                          buttons[i],
                          if (i != buttons.length - 1)
                            const SizedBox(height: 10),
                        ],
                      ],
                    );
                  }
                  return Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      for (var i = 0; i < buttons.length; i++) ...[
                        buttons[i],
                        if (i != buttons.length - 1)
                          const SizedBox(width: 12),
                      ],
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AutoUpdateIndicator extends StatelessWidget {
  const _AutoUpdateIndicator();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: const BoxDecoration(
            color: Color(0xFF22C55E),
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 6),
        const Text(
          'Auto-updates',
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w600,
            color: Color(0xFF64748B),
          ),
        ),
      ],
    );
  }
}

class _AutoAssignmentPreview extends StatelessWidget {
  const _AutoAssignmentPreview({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      decoration: BoxDecoration(
        color: const Color(0xFFEAF8F5),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFB8DDD8)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.auto_awesome_rounded,
            size: 18,
            color: Color(0xFF0F766E),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 12,
                height: 1.35,
                fontWeight: FontWeight.w700,
                color: Color(0xFF115E59),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PreferenceChip extends StatelessWidget {
  const _PreferenceChip({
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF1B6B72) : const Color(0xFFF5F5F5),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected ? const Color(0xFF1B6B72) : const Color(0xFFE0E0E0),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: isSelected ? Colors.white : const Color(0xFF4B5563),
          ),
        ),
      ),
    );
  }
}

class _QueueRow extends StatelessWidget {
  const _QueueRow({
    required this.entry,
    required this.profileImageUrl,
    required this.isSelected,
    required this.isDisabled,
    required this.emphasized,
    required this.onTap,
  });

  final TherapistQueueEntry entry;
  final String profileImageUrl;
  final bool isSelected;
  final bool isDisabled;
  final bool emphasized;
  final VoidCallback? onTap;

  String get _statusLabel {
    final base = entry.isFreeNow
        ? 'Free now'
        : entry.isReserved || entry.isTentativeHold
        ? _reservationLabel(entry)
        : 'Busy until ${_formatClock(entry.freeAt)}';
    return base;
  }

  Color get _statusColor {
    if (entry.isFreeNow) return const Color(0xFF4CAF50);
    if (entry.isReserved || entry.isTentativeHold) {
      return const Color(0xFF2563EB);
    }
    return const Color(0xFFF59E0B);
  }

  static String _reservationLabel(TherapistQueueEntry entry) {
    final start = entry.reservationStartAt;
    final end = entry.reservationEndAt;
    if (start != null && start.isNotEmpty && end != null && end.isNotEmpty) {
      return 'Reserved ${_formatClock(start)}–${_formatClock(end)}';
    }
    return 'Reserved until ${_formatClock(end ?? entry.freeAt)}';
  }

  static String _formatClock(String? hhmm) {
    if (hhmm == null || hhmm.isEmpty) return 'later';
    final parts = hhmm.split(':');
    if (parts.length < 2) return hhmm;
    final hour = int.tryParse(parts[0]);
    final minute = int.tryParse(parts[1]);
    if (hour == null || minute == null) return hhmm;
    return DateFormat('h:mm a').format(DateTime(2000, 1, 1, hour, minute));
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 150),
        opacity: isDisabled ? 0.4 : 1.0,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            // Only an actual selection is highlighted. The up-next therapist
            // keeps a neutral row (marked by the sparkle only) so a
            // recommendation never reads as an already-made choice.
            color: isSelected ? const Color(0xFFDDF1F1) : Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isSelected
                  ? const Color(0xFF1B6B72)
                  : const Color(0xFFE2E8F0),
              width: isSelected ? 2 : 1,
            ),
          ),
          child: Row(
            children: [
              _QueueTherapistAvatar(
                name: entry.name,
                imageUrl: profileImageUrl,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            entry.name,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF1A1A2E),
                            ),
                          ),
                        ),
                        if (emphasized) ...[
                          const SizedBox(width: 7),
                          const Tooltip(
                            message: 'Up next in the live queue',
                            child: Icon(
                              Icons.auto_awesome,
                              size: 18,
                              color: Color(0xFF1B6B72),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: _statusColor,
                          ),
                        ),
                        const SizedBox(width: 5),
                        Flexible(
                          child: Text(
                            _statusLabel,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: _statusColor,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Icon(
                isSelected ? Icons.check_circle : Icons.chevron_right_rounded,
                size: isSelected ? 19 : 20,
                color: isSelected
                    ? const Color(0xFF1B6B72)
                    : const Color(0xFF94A3B8),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _QueueTherapistAvatar extends StatelessWidget {
  const _QueueTherapistAvatar({required this.name, required this.imageUrl});

  final String name;
  final String imageUrl;

  @override
  Widget build(BuildContext context) {
    final fallback = Container(
      width: 42,
      height: 42,
      alignment: Alignment.center,
      decoration: const BoxDecoration(
        color: Color(0xFFE8F5F5),
        shape: BoxShape.circle,
      ),
      child: Text(
        staffInitials(name),
        style: const TextStyle(
          color: Color(0xFF1B6B72),
          fontSize: 12,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
    if (imageUrl.trim().isEmpty) return fallback;
    return ClipOval(
      child: CachedNetworkImage(
        imageUrl: imageUrl,
        width: 42,
        height: 42,
        fit: BoxFit.cover,
        placeholder: (_, _) => fallback,
        errorWidget: (_, _, _) => fallback,
      ),
    );
  }
}
