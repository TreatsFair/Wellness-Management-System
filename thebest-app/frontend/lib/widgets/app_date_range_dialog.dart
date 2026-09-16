import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

const _teal = Color(0xFF1B6B72);
const _ink = Color(0xFF111827);
const _muted = Color(0xFF6B7280);
const _line = Color(0xFFE5E7EB);

DateTime _dateOnly(DateTime date) =>
    DateTime(date.year, date.month, date.day);

Future<DateTimeRange?> showAppDateRangeDialog({
  required BuildContext context,
  required DateTime initialStartDate,
  required DateTime initialEndDate,
  required DateTime firstDate,
  required DateTime lastDate,
}) =>
    showDialog<DateTimeRange>(
      context: context,
      builder: (context) => AppDateRangeDialog(
        initialStartDate: initialStartDate,
        initialEndDate: initialEndDate,
        firstDate: firstDate,
        lastDate: lastDate,
      ),
    );

class AppDateRangeDialog extends StatefulWidget {
  const AppDateRangeDialog({
    super.key,
    required this.initialStartDate,
    required this.initialEndDate,
    required this.firstDate,
    required this.lastDate,
  });

  final DateTime initialStartDate;
  final DateTime initialEndDate;
  final DateTime firstDate;
  final DateTime lastDate;

  @override
  State<AppDateRangeDialog> createState() => _AppDateRangeDialogState();
}

class _AppDateRangeDialogState extends State<AppDateRangeDialog> {
  late DateTime _firstDate;
  late DateTime _lastDate;
  late DateTime _startDate;
  late DateTime _endDate;
  late DateTime _visibleMonth;
  bool _selectingStart = true;

  @override
  void initState() {
    super.initState();
    _firstDate = _dateOnly(widget.firstDate);
    _lastDate = _dateOnly(widget.lastDate);
    _startDate = _clampDate(_dateOnly(widget.initialStartDate));
    _endDate = _clampDate(_dateOnly(widget.initialEndDate));
    if (_endDate.isBefore(_startDate)) _endDate = _startDate;
    _visibleMonth = DateTime(_startDate.year, _startDate.month);
  }

  DateTime _clampDate(DateTime date) {
    if (date.isBefore(_firstDate)) return _firstDate;
    if (date.isAfter(_lastDate)) return _lastDate;
    return date;
  }

  bool _isSameDate(DateTime first, DateTime second) =>
      first.year == second.year &&
      first.month == second.month &&
      first.day == second.day;

  String _rangeText() {
    if (_isSameDate(_startDate, _endDate)) {
      return DateFormat('d MMM yyyy').format(_startDate);
    }
    return '${DateFormat('d MMM').format(_startDate)} – ${DateFormat('d MMM yyyy').format(_endDate)}';
  }

  void _moveMonth(int offset) {
    final nextMonth = DateTime(
      _visibleMonth.year,
      _visibleMonth.month + offset,
    );
    final firstMonth = DateTime(_firstDate.year, _firstDate.month);
    final lastMonth = DateTime(_lastDate.year, _lastDate.month);
    if (nextMonth.isBefore(firstMonth) || nextMonth.isAfter(lastMonth)) return;
    setState(() => _visibleMonth = nextMonth);
  }

  void _activateStart() {
    setState(() {
      _selectingStart = true;
      _visibleMonth = DateTime(_startDate.year, _startDate.month);
    });
  }

  void _activateEnd() {
    setState(() {
      _selectingStart = false;
      _visibleMonth = DateTime(_endDate.year, _endDate.month);
    });
  }

  void _selectDate(DateTime date) {
    final cleanDate = _dateOnly(date);
    if (cleanDate.isBefore(_firstDate) || cleanDate.isAfter(_lastDate)) return;
    setState(() {
      if (_selectingStart) {
        _startDate = cleanDate;
        if (_endDate.isBefore(_startDate)) _endDate = _startDate;
        _selectingStart = false;
      } else if (cleanDate.isBefore(_startDate)) {
        _endDate = _startDate;
        _startDate = cleanDate;
      } else {
        _endDate = cleanDate;
      }
      _visibleMonth = DateTime(cleanDate.year, cleanDate.month);
    });
  }

  Widget _dateButton({
    required String label,
    required DateTime date,
    required bool active,
    required VoidCallback onTap,
  }) =>
      Expanded(
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            decoration: BoxDecoration(
              color: active ? _teal.withValues(alpha: 0.08) : Colors.white,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: active ? _teal : _line),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: active ? _teal : _muted,
                    fontSize: 10,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  DateFormat('d MMM yyyy').format(date),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: _ink,
                    fontSize: 13,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ),
          ),
        ),
      );

  Widget _dayCell(DateTime day, DateTime today) {
    final cleanDay = _dateOnly(day);
    final inMonth = day.month == _visibleMonth.month;
    final disabled =
        cleanDay.isBefore(_firstDate) || cleanDay.isAfter(_lastDate);
    final inRange = !cleanDay.isBefore(_startDate) &&
        !cleanDay.isAfter(_endDate) &&
        !disabled;
    final endpoint =
        _isSameDate(cleanDay, _startDate) || _isSameDate(cleanDay, _endDate);
    final isToday = _isSameDate(cleanDay, today);

    return InkWell(
      onTap: disabled ? null : () => _selectDate(cleanDay),
      borderRadius: BorderRadius.circular(20),
      child: Container(
        decoration: BoxDecoration(
          color: inRange ? _teal.withValues(alpha: 0.10) : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        alignment: Alignment.center,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: endpoint ? _teal : Colors.transparent,
            border: isToday && !endpoint ? Border.all(color: _teal) : null,
          ),
          alignment: Alignment.center,
          child: Text(
            '${day.day}',
            style: TextStyle(
              color: disabled
                  ? _muted.withValues(alpha: 0.30)
                  : endpoint
                  ? Colors.white
                  : inMonth
                  ? _ink
                  : _muted,
              fontSize: 13,
              fontWeight:
                  endpoint || isToday ? FontWeight.w900 : FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final phone = MediaQuery.sizeOf(context).width < 600;
    final firstDay = DateTime(_visibleMonth.year, _visibleMonth.month, 1);
    final gridStart = firstDay.subtract(Duration(days: firstDay.weekday % 7));
    final days = List.generate(
      42,
      (index) => gridStart.add(Duration(days: index)),
    );
    final today = _dateOnly(DateTime.now());
    final firstMonth = DateTime(_firstDate.year, _firstDate.month);
    final lastMonth = DateTime(_lastDate.year, _lastDate.month);
    final canMovePrevious = _visibleMonth.isAfter(firstMonth);
    final canMoveNext = _visibleMonth.isBefore(lastMonth);

    return Dialog(
      insetPadding: EdgeInsets.symmetric(
        horizontal: phone ? 12 : 24,
        vertical: 24,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            phone ? 14 : 18,
            14,
            phone ? 14 : 18,
            14,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Custom date range',
                          style: TextStyle(
                            color: _ink,
                            fontSize: 18,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '${_rangeText()} · ${_selectingStart ? 'Choose a start date' : 'Choose an end date'}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: _muted,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  _dateButton(
                    label: 'FROM',
                    date: _startDate,
                    active: _selectingStart,
                    onTap: _activateStart,
                  ),
                  const SizedBox(width: 8),
                  _dateButton(
                    label: 'TO',
                    date: _endDate,
                    active: !_selectingStart,
                    onTap: _activateEnd,
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      DateFormat('MMMM yyyy').format(_visibleMonth),
                      style: const TextStyle(
                        color: _ink,
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Previous month',
                    onPressed: canMovePrevious ? () => _moveMonth(-1) : null,
                    icon: const Icon(Icons.chevron_left_rounded),
                    visualDensity: VisualDensity.compact,
                  ),
                  IconButton(
                    tooltip: 'Next month',
                    onPressed: canMoveNext ? () => _moveMonth(1) : null,
                    icon: const Icon(Icons.chevron_right_rounded),
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  for (final label in const ['S', 'M', 'T', 'W', 'T', 'F', 'S'])
                    Expanded(
                      child: Text(
                        label,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: _muted,
                          fontSize: 11,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 7,
                  mainAxisSpacing: 4,
                  crossAxisSpacing: 4,
                ),
                itemCount: days.length,
                itemBuilder: (context, index) => _dayCell(days[index], today),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const Spacer(),
                  FilledButton(
                    onPressed: () => Navigator.of(context).pop(
                      DateTimeRange(start: _startDate, end: _endDate),
                    ),
                    style: FilledButton.styleFrom(
                      backgroundColor: _teal,
                      foregroundColor: Colors.white,
                    ),
                    child: const Text('Apply'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
