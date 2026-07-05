import 'package:flutter/material.dart';

import '../../core/outlets/outlet_context.dart';
import '../../data/repositories/online_booking_repository.dart';

class OnlineBookingScreen extends StatefulWidget {
  const OnlineBookingScreen({super.key});

  @override
  State<OnlineBookingScreen> createState() => _OnlineBookingScreenState();
}

class _OnlineBookingScreenState extends State<OnlineBookingScreen> {
  final _repository = OnlineBookingRepository();
  String _outletId = OutletContext.activeOutletId.value;
  Map<String, dynamic>? _data;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Unable to load online booking: $error')),
      );
    }
  }

  List<Map<String, dynamic>> _list(String key) =>
      List<Map<String, dynamic>>.from(_data?[key] as List? ?? const []);

  @override
  Widget build(BuildContext context) {
    final outlet = OutletContext.outletById(_outletId);
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        backgroundColor: const Color(0xFFF6F3EE),
        appBar: AppBar(
          title: const Text(
            'Online Booking',
            style: TextStyle(fontWeight: FontWeight.w800),
          ),
          backgroundColor: Colors.white,
          foregroundColor: const Color(0xFF201A12),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: _outletId,
                  items: OutletContext.outlets
                      .map(
                        (item) => DropdownMenuItem(
                          value: item.id,
                          child: Text(item.name),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value == null) return;
                    setState(() => _outletId = value);
                    OutletContext.select(value);
                    _load();
                  },
                ),
              ),
            ),
          ],
          bottom: const TabBar(
            labelColor: Color(0xFFB7790B),
            tabs: [
              Tab(text: 'Outlet rules'),
              Tab(text: 'Public services'),
              Tab(text: 'Closures'),
            ],
          ),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _data == null
            ? Center(
                child: FilledButton(
                  onPressed: _load,
                  child: const Text('Retry'),
                ),
              )
            : TabBarView(
                children: [
                  _SettingsPane(
                    outletName: outlet.name,
                    initial: Map<String, dynamic>.from(
                      _data!['settings'] as Map,
                    ),
                    onSave: (values) async {
                      await _repository.saveSettings(_outletId, values);
                      await _load();
                    },
                  ),
                  _ServicesPane(
                    catalogue: _list('catalogue'),
                    services: _list('services'),
                    rooms: _list('rooms'),
                    roomLinks: _list('roomLinks'),
                    hours: _list('hours'),
                    onEdit: (item) => _editService(item),
                    onDelete: (id) async {
                      await _repository.deleteService(id);
                      await _load();
                    },
                  ),
                  _ClosuresPane(
                    outletId: _outletId,
                    closures: _list('closures'),
                    onAdd: (value) async {
                      await _repository.addClosure(value);
                      await _load();
                    },
                    onDelete: (id) async {
                      await _repository.deleteClosure(id);
                      await _load();
                    },
                  ),
                ],
              ),
      ),
    );
  }

  Future<void> _editService(Map<String, dynamic>? item) async {
    final result = await showDialog<_ServiceDraft>(
      context: context,
      builder: (_) => _OnlineServiceDialog(
        item: item,
        services: _list('services'),
        rooms: _list('rooms'),
        roomLinks: _list('roomLinks'),
        hours: _list('hours'),
      ),
    );
    if (result == null) return;
    await _repository.saveService(
      outletId: _outletId,
      id: item?['id']?.toString(),
      values: result.values,
      roomIds: result.roomIds,
      hours: result.hours,
    );
    await _load();
  }
}

class _SettingsPane extends StatefulWidget {
  const _SettingsPane({
    required this.outletName,
    required this.initial,
    required this.onSave,
  });
  final String outletName;
  final Map<String, dynamic> initial;
  final Future<void> Function(Map<String, dynamic>) onSave;
  @override
  State<_SettingsPane> createState() => _SettingsPaneState();
}

class _SettingsPaneState extends State<_SettingsPane> {
  late bool enabled, therapistSelection;
  late final TextEditingController open, close, notice;
  bool saving = false;
  @override
  void initState() {
    super.initState();
    enabled = widget.initial['online_booking_enabled'] == true;
    therapistSelection =
        widget.initial['customer_therapist_selection_allowed'] != false;
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
  }

  @override
  void dispose() {
    open.dispose();
    close.dispose();
    notice.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      _card(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.outletName,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
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
          children: [
            Row(
              children: [
                Expanded(child: _field(open, 'Public opening', '11:00')),
                const SizedBox(width: 12),
                Expanded(child: _field(close, 'Public closing', '22:00')),
              ],
            ),
            const SizedBox(height: 12),
            _field(
              notice,
              'Minimum advance notice (minutes)',
              '60',
              number: true,
            ),
            const ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.schedule),
              title: Text('Start interval'),
              trailing: Text('Every 30 minutes'),
            ),
            const ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.date_range),
              title: Text('Booking window'),
              trailing: Text('Tomorrow → next 7 dates'),
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
      const SizedBox(height: 20),
      FilledButton.icon(
        onPressed: saving
            ? null
            : () async {
                setState(() => saving = true);
                await widget.onSave({
                  'online_booking_enabled': enabled,
                  'public_open_time': open.text.trim(),
                  'public_close_time': close.text.trim(),
                  'minimum_advance_minutes': int.tryParse(notice.text) ?? 60,
                  'customer_therapist_selection_allowed': therapistSelection,
                });
                if (mounted) setState(() => saving = false);
              },
        icon: const Icon(Icons.save_outlined),
        label: Text(saving ? 'Saving…' : 'Save outlet rules'),
      ),
    ],
  );
}

class _ServicesPane extends StatelessWidget {
  const _ServicesPane({
    required this.catalogue,
    required this.services,
    required this.rooms,
    required this.roomLinks,
    required this.hours,
    required this.onEdit,
    required this.onDelete,
  });
  final List<Map<String, dynamic>> catalogue, services, rooms, roomLinks, hours;
  final void Function(Map<String, dynamic>?) onEdit;
  final Future<void> Function(String) onDelete;
  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      Row(
        children: [
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Public catalogue',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
                ),
                Text('Only complete, enabled listings appear online.'),
              ],
            ),
          ),
          FilledButton.icon(
            onPressed: () => onEdit(null),
            icon: const Icon(Icons.add),
            label: const Text('Add service'),
          ),
        ],
      ),
      const SizedBox(height: 16),
      if (catalogue.isEmpty)
        _card(
          const Padding(
            padding: EdgeInsets.all(20),
            child: Center(child: Text('No public services configured yet.')),
          ),
        ),
      ...catalogue.map((item) {
        final internal = services
            .where((s) => s['id'] == item['service_id'])
            .firstOrNull;
        final live = item['enabled'] == true;
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: _card(
            ListTile(
              contentPadding: const EdgeInsets.all(10),
              leading: CircleAvatar(
                backgroundColor: live
                    ? const Color(0xFFFFE0A3)
                    : Colors.grey.shade200,
                child: Icon(
                  live ? Icons.public : Icons.public_off,
                  color: const Color(0xFF9A6500),
                ),
              ),
              title: Text(
                (item['public_name'] as String?)?.trim().isNotEmpty == true
                    ? item['public_name']
                    : 'Draft public service',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: Text(
                '${internal?['name'] ?? 'Missing internal service'} · ${internal?['duration'] ?? 0} min · Full payment RM ${item['display_price'] ?? 0}',
              ),
              trailing: PopupMenuButton<String>(
                onSelected: (v) => v == 'edit'
                    ? onEdit(item)
                    : onDelete(item['id'].toString()),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'edit', child: Text('Edit')),
                  PopupMenuItem(value: 'delete', child: Text('Delete')),
                ],
              ),
            ),
          ),
        );
      }),
    ],
  );
}

class _ServiceDraft {
  const _ServiceDraft(this.values, this.roomIds, this.hours);
  final Map<String, dynamic> values;
  final Set<String> roomIds;
  final List<Map<String, dynamic>> hours;
}

class _OnlineServiceDialog extends StatefulWidget {
  const _OnlineServiceDialog({
    required this.item,
    required this.services,
    required this.rooms,
    required this.roomLinks,
    required this.hours,
  });
  final Map<String, dynamic>? item;
  final List<Map<String, dynamic>> services, rooms, roomLinks, hours;
  @override
  State<_OnlineServiceDialog> createState() => _OnlineServiceDialogState();
}

class _OnlineServiceDialogState extends State<_OnlineServiceDialog> {
  final form = GlobalKey<FormState>();
  late String? serviceId;
  late final TextEditingController name,
      description,
      image,
      price,
      order,
      before,
      after,
      capacity,
      start,
      end;
  late bool enabled, showPrice, custom;
  late Set<String> roomIds;
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
    image = TextEditingController(
      text: i['public_image_url']?.toString() ?? '',
    );
    price = TextEditingController(text: '${i['display_price'] ?? ''}');
    order = TextEditingController(text: '${i['display_order'] ?? 0}');
    before = TextEditingController(text: '${i['buffer_before_minutes'] ?? 0}');
    after = TextEditingController(text: '${i['buffer_after_minutes'] ?? 0}');
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
      image,
      price,
      order,
      before,
      after,
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
    return AlertDialog(
      title: Text(
        widget.item == null ? 'Add online service' : 'Edit online service',
      ),
      content: SizedBox(
        width: 650,
        child: Form(
          key: form,
          child: SingleChildScrollView(
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
                      'Scheduling duration: ${internal['duration']} minutes (read-only)',
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
                _field(image, 'Public image URL', 'https://…', required: true),
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
                    'Buffers reserve the therapist and room around the appointment for preparation or cleanup. Customers only see the actual treatment time.',
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
                    title: Text(
                      '${r['name']} (${r['total_slots'] ?? 1} slots)',
                    ),
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
                        'Maximum concurrent',
                        '3',
                        number: true,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _field(
                        before,
                        'Buffer before (min)',
                        '0',
                        number: true,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _field(
                        after,
                        'Buffer after (min)',
                        '0',
                        number: true,
                      ),
                    ),
                  ],
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Use custom service hours'),
                  subtitle: const Text(
                    'Otherwise inherits outlet public hours',
                  ),
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
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            if (!form.currentState!.validate() ||
                serviceId == null ||
                roomIds.isEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text(
                    'Complete the public fields and select at least one room.',
                  ),
                ),
              );
              return;
            }
            final configuredHours = custom
                ? weekdays
                      .map(
                        (d) => <String, dynamic>{
                          'day_of_week': d,
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
                  'public_image_url': image.text.trim(),
                  'display_price': double.tryParse(price.text) ?? 0,
                  'display_order': int.tryParse(order.text) ?? 0,
                  'show_price': showPrice,
                  'buffer_before_minutes': int.tryParse(before.text) ?? 0,
                  'buffer_after_minutes': int.tryParse(after.text) ?? 0,
                  'maximum_concurrent_bookings':
                      int.tryParse(capacity.text) ?? 3,
                  'use_custom_hours': custom,
                  'enabled': enabled,
                },
                roomIds,
                configuredHours,
              ),
            );
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _ClosuresPane extends StatelessWidget {
  const _ClosuresPane({
    required this.outletId,
    required this.closures,
    required this.onAdd,
    required this.onDelete,
  });
  final String outletId;
  final List<Map<String, dynamic>> closures;
  final Future<void> Function(Map<String, dynamic>) onAdd;
  final Future<void> Function(String) onDelete;

  Future<void> _addClosure(BuildContext context) async {
    final date = await showDatePicker(
      context: context,
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      initialDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (date == null || !context.mounted) return;
    var fullDay = true;
    final start = TextEditingController(text: '11:00');
    final end = TextEditingController(text: '12:00');
    final reason = TextEditingController();
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: const Text('Add closure'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Close the full day'),
                value: fullDay,
                onChanged: (value) => setLocal(() => fullDay = value),
              ),
              if (!fullDay)
                Row(
                  children: [
                    Expanded(child: _field(start, 'From', '11:00')),
                    const SizedBox(width: 10),
                    Expanded(child: _field(end, 'Until', '12:00')),
                  ],
                ),
              const SizedBox(height: 12),
              _field(reason, 'Internal reason', 'Maintenance, holiday…'),
            ],
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
      await onAdd({
        'outlet_id': outletId,
        'closure_date':
            '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}',
        'is_full_day': fullDay,
        'start_time': fullDay ? null : start.text.trim(),
        'end_time': fullDay ? null : end.text.trim(),
        'internal_reason': reason.text.trim(),
      });
    }
    start.dispose();
    end.dispose();
    reason.dispose();
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      Row(
        children: [
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Closed & blackout dates',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
                ),
                Text('Internal reasons are never shown publicly.'),
              ],
            ),
          ),
          FilledButton.icon(
            onPressed: () => _addClosure(context),
            icon: const Icon(Icons.event_busy),
            label: const Text('Add closure'),
          ),
        ],
      ),
      const SizedBox(height: 16),
      ...closures.map(
        (c) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: _card(
            ListTile(
              leading: const Icon(Icons.block, color: Colors.redAccent),
              title: Text(c['closure_date'].toString()),
              subtitle: Text(
                c['is_full_day'] == true
                    ? 'Full day'
                    : '${c['start_time']} – ${c['end_time']}',
              ),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () => onDelete(c['id'].toString()),
              ),
            ),
          ),
        ),
      ),
    ],
  );
}

Widget _card(Widget child) => Container(
  decoration: BoxDecoration(
    color: Colors.white,
    borderRadius: BorderRadius.circular(16),
    boxShadow: [
      BoxShadow(color: Colors.black.withValues(alpha: .05), blurRadius: 18),
    ],
  ),
  padding: const EdgeInsets.all(16),
  child: child,
);
Widget _field(
  TextEditingController controller,
  String label,
  String hint, {
  bool number = false,
  bool required = false,
  int lines = 1,
}) => TextFormField(
  controller: controller,
  maxLines: lines,
  keyboardType: number ? TextInputType.number : null,
  decoration: InputDecoration(
    labelText: label,
    hintText: hint,
    border: const OutlineInputBorder(),
  ),
  validator: (v) => required && v!.trim().isEmpty ? 'Required' : null,
);
