import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../customers/customer_screen.dart';
import '../therapists/therapist_screen.dart';

// TODO: replace with Firestore call in Week 7.
class _DashboardStats {
  final int todayAppointments;
  final int tomorrowAppointments;
  final int doneAppointments;
  final int pendingAppointments;
  final double todaySales;
  final int totalTransactions;
  final int totalCustomers;
  final int newCustomersThisWeek;
  final double weekRevenue;
  final int weekAppointments;
  final double averageTransactionValue;

  const _DashboardStats({
    required this.todayAppointments,
    required this.tomorrowAppointments,
    required this.doneAppointments,
    required this.pendingAppointments,
    required this.todaySales,
    required this.totalTransactions,
    required this.totalCustomers,
    required this.newCustomersThisWeek,
    required this.weekRevenue,
    required this.weekAppointments,
    required this.averageTransactionValue,
  });

  static const placeholder = _DashboardStats(
    todayAppointments: 67,
    tomorrowAppointments: 8,
    doneAppointments: 4,
    pendingAppointments: 8,
    todaySales: 1240,
    totalTransactions: 12,
    totalCustomers: 124,
    newCustomersThisWeek: 8,
    weekRevenue: 4820,
    weekAppointments: 47,
    averageTransactionValue: 103,
  );
}

class _TherapistStatus {
  final String name;
  final String status;
  final bool isFree;
  final int doneCount;

  const _TherapistStatus({
    required this.name,
    required this.status,
    required this.isFree,
    required this.doneCount,
  });
}

class _MemberSummary {
  final String name;
  final String phone;

  const _MemberSummary({
    required this.name,
    required this.phone,
  });
}

class _PendingOrder {
  final String customerName;
  final String phone;
  final double amount;
  final int pendingCount;

  const _PendingOrder({
    required this.customerName,
    required this.phone,
    required this.amount,
    required this.pendingCount,
  });
}

class _BusinessProfile {
  final String name;
  final String location;
  final String logoInitial;
  final String? settingsDocumentId;

  const _BusinessProfile({
    required this.name,
    required this.location,
    required this.logoInitial,
    this.settingsDocumentId,
  });

  _BusinessProfile copyWith({
    String? name,
    String? location,
    String? logoInitial,
    String? settingsDocumentId,
  }) {
    return _BusinessProfile(
      name: name ?? this.name,
      location: location ?? this.location,
      logoInitial: logoInitial ?? this.logoInitial,
      settingsDocumentId: settingsDocumentId ?? this.settingsDocumentId,
    );
  }
}

class _TransactionSummary {
  final String customerName;
  final String serviceName;
  final String date;
  final String time;
  final double amount;

  const _TransactionSummary({
    required this.customerName,
    required this.serviceName,
    required this.date,
    required this.time,
    required this.amount,
  });
}

// TODO: replace with Firestore call in Week 7.
const _placeholderBusinessProfile = _BusinessProfile(
  name: 'The Best Family Wellness',
  location: 'Kuala Lumpur',
  logoInitial: 'W',
);

const _businessSettingsDocumentId = 'mAERFw4PbxfgzILaNV1X';

// TODO: replace with Firestore call in Week 7.
const _placeholderTherapists = [
  _TherapistStatus(
    name: 'Aisha Rahman',
    status: 'Free now',
    isFree: true,
    doneCount: 3,
  ),
  _TherapistStatus(
    name: 'Wei Chen',
    status: 'Busy until 2:30 PM',
    isFree: false,
    doneCount: 5,
  ),
  _TherapistStatus(
    name: 'Priya Kumar',
    status: 'Free now',
    isFree: true,
    doneCount: 2,
  ),
  _TherapistStatus(
    name: 'Ahmad Ismail',
    status: 'Busy until 3:15 PM',
    isFree: false,
    doneCount: 4,
  ),
];

// TODO: replace with Firestore call in Week 7.
const _placeholderRecentMembers = [
  _MemberSummary(name: 'Ahmad Razif', phone: '(6012) 345-6789'),
  _MemberSummary(name: 'Siti Nurhaliza', phone: '(6015) 987-6543'),
];

// TODO: replace with Firestore call in Week 7.
const _placeholderPendingOrder = _PendingOrder(
  customerName: 'Lim Wei Xin',
  phone: '(6010) 234-5678',
  amount: 120,
  pendingCount: 2,
);

// TODO: replace with Firestore call in Week 7.
const _placeholderTransactions = [
  _TransactionSummary(
    customerName: 'Lim Wei Xin',
    serviceName: 'Traditional Massage',
    date: '28 May 2026',
    time: '2:15 PM',
    amount: 180,
  ),
  _TransactionSummary(
    customerName: 'Siti Nurhaliza',
    serviceName: 'Hot Stone Therapy',
    date: '28 May 2026',
    time: '1:30 PM',
    amount: 220,
  ),
  _TransactionSummary(
    customerName: 'Ahmad Razif',
    serviceName: 'Aromatherapy',
    date: '28 May 2026',
    time: '11:45 AM',
    amount: 150,
  ),
  _TransactionSummary(
    customerName: 'Priya Kumar',
    serviceName: 'Deep Tissue + Scrub',
    date: '28 May 2026',
    time: '10:20 AM',
    amount: 280,
  ),
  _TransactionSummary(
    customerName: 'Wong Mei Ling',
    serviceName: 'Reflexology',
    date: '28 May 2026',
    time: '9:40 AM',
    amount: 160,
  ),
  _TransactionSummary(
    customerName: 'Nur Aina',
    serviceName: 'Facial Treatment',
    date: '28 May 2026',
    time: '9:10 AM',
    amount: 190,
  ),
];

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  _BusinessProfile _businessProfile = _placeholderBusinessProfile;
  bool _isCurrentUserAdmin = false;
  String _currentUserRole = 'staff';
  bool _isLoadingBusinessSettings = true;

  @override
  void initState() {
    super.initState();
    _loadBusinessSettings();
  }

  bool _isTablet(BuildContext context) =>
      MediaQuery.of(context).size.width >= 600;

  Future<void> _loadBusinessSettings() async {
    final currentUser = FirebaseAuth.instance.currentUser;
    final uid = currentUser?.uid;
    final email = currentUser?.email;

    var profile = _placeholderBusinessProfile;
    var normalizedRole = 'staff';

    Map<String, dynamic>? userData;
    if (email != null) {
      try {
        final trimmedEmail = email.trim();
        final emailCandidates = {
          trimmedEmail.toLowerCase(),
          trimmedEmail,
        }.where((value) => value.isNotEmpty);
        final userDocs = <QueryDocumentSnapshot<Map<String, dynamic>>>[];

        for (final emailCandidate in emailCandidates) {
          final userByEmailSnapshot = await FirebaseFirestore.instance
              .collection('users')
              .where('email', isEqualTo: emailCandidate)
              .get(const GetOptions(source: Source.server));
          userDocs.addAll(userByEmailSnapshot.docs);
        }

        if (userDocs.isNotEmpty) {
          QueryDocumentSnapshot<Map<String, dynamic>>? selectedDoc;
          for (final doc in userDocs) {
            if (doc.id == uid || doc.data()['uid'] == uid) {
              selectedDoc = doc;
              break;
            }
          }
          if (selectedDoc == null) {
            for (final doc in userDocs) {
              if ((doc.data()['role'] as String?)?.toLowerCase().trim() ==
                  'admin') {
                selectedDoc = doc;
                break;
              }
            }
          }
          userData = (selectedDoc ?? userDocs.first).data();
        }
      } on FirebaseException catch (e) {
        debugPrint('Unable to load user role by email: ${e.code}');
      }
    }

    if (userData == null && uid != null) {
      try {
        final userByUidSnapshot =
            await FirebaseFirestore.instance
                .collection('users')
                .doc(uid)
                .get(const GetOptions(source: Source.server));
        userData = userByUidSnapshot.data();
      } on FirebaseException catch (e) {
        debugPrint('Unable to load user role by uid: ${e.code}');
      }
    }

    if (userData != null) {
      final role = (userData['role'] as String?)?.toLowerCase().trim();
      normalizedRole = role == 'admin' ? 'admin' : 'staff';
    }

    try {
      final settingsDoc = await FirebaseFirestore.instance
          .collection('settings')
          .doc(_businessSettingsDocumentId)
          .get();
      if (settingsDoc.exists) {
        final data = settingsDoc.data();
        profile = _BusinessProfile(
          name: (data?['businessName'] as String?)?.trim().isNotEmpty == true
              ? (data?['businessName'] as String).trim()
              : _placeholderBusinessProfile.name,
          location: (data?['location'] as String?)?.trim().isNotEmpty == true
              ? (data?['location'] as String).trim()
              : _placeholderBusinessProfile.location,
          logoInitial: _placeholderBusinessProfile.logoInitial,
          settingsDocumentId: settingsDoc.id,
        );
      }
    } on FirebaseException catch (e) {
      debugPrint('Unable to load business settings: ${e.code}');
    }

    if (!mounted) return;
    setState(() {
      _businessProfile = profile;
      _isCurrentUserAdmin = normalizedRole == 'admin';
      _currentUserRole = normalizedRole;
      _isLoadingBusinessSettings = false;
    });
  }

  Future<void> _saveBusinessSettings(_BusinessProfile profile) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (!_isCurrentUserAdmin || uid == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Only admins can edit business settings'),
          backgroundColor: Color(0xFFE53935),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    final settingsDocumentId =
        profile.settingsDocumentId ?? _businessSettingsDocumentId;

    try {
      await FirebaseFirestore.instance
          .collection('settings')
          .doc(settingsDocumentId)
          .set({
        'businessName': profile.name,
        'location': profile.location,
        'updatedAt': FieldValue.serverTimestamp(),
        'updatedBy': uid,
      }, SetOptions(merge: true));

      if (!mounted) return;
      setState(() {
        _businessProfile =
            profile.copyWith(settingsDocumentId: settingsDocumentId);
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Business settings updated'),
          backgroundColor: Color(0xFF1B6B72),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } on FirebaseException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Unable to save business settings: ${e.code}'),
          backgroundColor: const Color(0xFFE53935),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _openBusinessSettings() async {
    final updatedProfile = await showDialog<_BusinessProfile>(
      context: context,
      builder: (context) => _BusinessSettingsDialog(
        profile: _businessProfile,
        isAdmin: _isCurrentUserAdmin,
      ),
    );

    if (updatedProfile == null) return;

    await _saveBusinessSettings(updatedProfile);
  }

  @override
  Widget build(BuildContext context) {
    final isTablet = _isTablet(context);
    return Scaffold(
      backgroundColor: const Color(0xFFF0F0F0),
      body: SafeArea(
        child: isTablet
            ? _TabletLayout(
                profile: _businessProfile,
                role: _currentUserRole,
                isLoadingSettings: _isLoadingBusinessSettings,
                onOpenSettings: _openBusinessSettings,
              )
            : _PhoneLayout(
                profile: _businessProfile,
                role: _currentUserRole,
                isLoadingSettings: _isLoadingBusinessSettings,
                onOpenSettings: _openBusinessSettings,
              ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// TABLET LAYOUT — landscape, grid-based like Image 1
// ─────────────────────────────────────────────────────────────────────────────
class _TabletLayout extends StatelessWidget {
  final _BusinessProfile profile;
  final String role;
  final bool isLoadingSettings;
  final VoidCallback onOpenSettings;

  const _TabletLayout({
    required this.profile,
    required this.role,
    required this.isLoadingSettings,
    required this.onOpenSettings,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // ── Top bar ────────────────────────────────────────────
        _TabletTopBar(
          profile: profile,
          role: role,
          isLoadingSettings: isLoadingSettings,
          onOpenSettings: onOpenSettings,
        ),

        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [

                // Main section label
                const _SectionLabel('Main'),
                const SizedBox(height: 12),

                // 4-column main cards row
                IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Members card
                      Expanded(
                        child: _TabletMembersCard(),
                      ),
                      const SizedBox(width: 16),
                      // Orders card
                      Expanded(
                        child: _TabletOrdersCard(),
                      ),
                      const SizedBox(width: 16),
                      // Appointment card
                      Expanded(
                        child: _TabletAppointmentCard(),
                      ),
                      const SizedBox(width: 16),
                      // Therapists card
                      Expanded(
                        child: _TabletTherapistsCard(role: role),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 32),

                // Others section label
                const _SectionLabel('Others'),
                const SizedBox(height: 12),

                // 4-column others row
                Row(
                  children: [
                    Expanded(child: _TabletOtherCard(
                      icon: Icons.history_outlined,
                      label: 'History',
                      iconBg: const Color(0xFFE8F4F8),
                      iconColor: const Color(0xFF5BA4B5),
                    )),
                    const SizedBox(width: 16),
                    Expanded(child: _TabletOtherCard(
                      icon: Icons.person_outline,
                      label: 'Attendance',
                      iconBg: const Color(0xFFFFF3E0),
                      iconColor: const Color(0xFFF59E0B),
                    )),
                    const SizedBox(width: 16),
                    Expanded(child: _TabletOtherCard(
                      icon: Icons.settings_outlined,
                      label: 'Settings',
                      iconBg: const Color(0xFFE8F5E9),
                      iconColor: const Color(0xFF4CAF50),
                      onTap: onOpenSettings,
                    )),
                    const SizedBox(width: 16),
                    Expanded(child: _TabletOtherCard(
                      icon: Icons.bar_chart_outlined,
                      label: 'Reports',
                      iconBg: const Color(0xFFEDE7F6),
                      iconColor: const Color(0xFF7C3AED),
                    )),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _TabletTopBar extends StatelessWidget {
  final _BusinessProfile profile;
  final String role;
  final bool isLoadingSettings;
  final VoidCallback onOpenSettings;

  const _TabletTopBar({
    required this.profile,
    required this.role,
    required this.isLoadingSettings,
    required this.onOpenSettings,
  });

  void _openBusinessProfile(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (context) => _BusinessProfileDialog(profile: profile),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
      child: Row(
        children: [
          InkWell(
            onTap: () => _openBusinessProfile(context),
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Row(
                children: [
                  Container(
                    width: 40, height: 40,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: Color(0xFF1B6B72),
                    ),
                    child: Center(
                      child: Text(profile.logoInitial,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        )),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(profile.name,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF1A1A2E),
                        )),
                      Text(profile.location,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF9E9E9E),
                        )),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const Spacer(),
          _RolePill(
            role: role,
            isLoading: isLoadingSettings,
          ),
          const SizedBox(width: 12),
          const _NotificationButton(),
          const SizedBox(width: 12),
          _SettingsButton(onPressed: onOpenSettings),
        ],
      ),
    );
  }
}

class _TabletMembersCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final members = _placeholderRecentMembers;

    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const CustomerScreen()),
      ),
      child: _TabletCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              _IconBox(
                icon: Icons.people_outline,
                bg: const Color(0xFFE3F2FD),
                color: const Color(0xFF1B6B72),
              ),
              const SizedBox(width: 12),
              const Text('Members',
                style: TextStyle(
                  fontSize: 16, fontWeight: FontWeight.w600,
                  color: Color(0xFF1A1A2E),
                )),
            ]),
            const SizedBox(height: 16),
            const Text('Recently added',
              style: TextStyle(fontSize: 12, color: Color(0xFF9E9E9E))),
            const SizedBox(height: 8),
            for (final member in members) ...[
              _MemberRow(name: member.name, phone: member.phone),
              if (member != members.last) const SizedBox(height: 6),
            ],
          ],
        ),
      ),
    );
  }
}

class _TabletOrdersCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    const order = _placeholderPendingOrder;

    return _TabletCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                _IconBox(
                  icon: Icons.shopping_cart_outlined,
                  bg: const Color(0xFFFFF3E0),
                  color: const Color(0xFFF59E0B),
                ),
                Positioned(
                  top: -4, right: -4,
                  child: Container(
                    width: 18, height: 18,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: Color(0xFFE53935),
                    ),
                    child: Center(
                      child: Text('${order.pendingCount}',
                        style: const TextStyle(
                          color: Colors.white, fontSize: 10,
                          fontWeight: FontWeight.bold,
                        )),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(width: 12),
            const Text('Orders',
              style: TextStyle(
                fontSize: 16, fontWeight: FontWeight.w600,
                color: Color(0xFF1A1A2E),
              )),
          ]),
          const SizedBox(height: 16),
          const Text('Pending order',
            style: TextStyle(fontSize: 12, color: Color(0xFF9E9E9E))),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(order.customerName,
                    style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w500,
                      color: Color(0xFF1A1A2E),
                    )),
                  const SizedBox(height: 2),
                  Text(order.phone,
                    style: const TextStyle(fontSize: 12, color: Color(0xFF9E9E9E))),
                ],
              ),
              Text('RM ${order.amount.toStringAsFixed(0)}',
                style: const TextStyle(
                  fontSize: 15, fontWeight: FontWeight.bold,
                  color: Color(0xFF1B6B72),
                )),
            ],
          ),
        ],
      ),
    );
  }
}

class _TabletAppointmentCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final stats = _DashboardStats.placeholder;

    return _TabletCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            _IconBox(
              icon: Icons.calendar_today_outlined,
              bg: const Color(0xFFE8F5E9),
              color: const Color(0xFF1B6B72),
            ),
            const SizedBox(width: 12),
            const Text('Appointment',
              style: TextStyle(
                fontSize: 16, fontWeight: FontWeight.w600,
                color: Color(0xFF1A1A2E),
              )),
          ]),
          const SizedBox(height: 16),
          const Text('Total',
            style: TextStyle(fontSize: 12, color: Color(0xFF9E9E9E))),
          const SizedBox(height: 10),
          _AppointmentRow(label: 'Today', count: '${stats.todayAppointments}'),
          const SizedBox(height: 10),
          _AppointmentRow(
            label: 'Tomorrow',
            count: '${stats.tomorrowAppointments}',
          ),
        ],
      ),
    );
  }
}

class _TabletTherapistsCard extends StatelessWidget {
  final String role;

  const _TabletTherapistsCard({required this.role});

  @override
  Widget build(BuildContext context) {
    final therapists = _placeholderTherapists.take(2).toList();

    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => TherapistsScreen(userRole: role),
        ),
      ),
      child: _TabletCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              _IconBox(
                icon: Icons.people_outline,
                bg: const Color(0xFFF3E8FF),
                color: const Color(0xFF7C3AED),
              ),
              const SizedBox(width: 12),
              const Text('Therapists',
                style: TextStyle(
                  fontSize: 16, fontWeight: FontWeight.w600,
                  color: Color(0xFF1A1A2E),
                )),
            ]),
            const SizedBox(height: 16),
            const Text('Status Today',
              style: TextStyle(fontSize: 12, color: Color(0xFF9E9E9E))),
            const SizedBox(height: 10),
            for (final therapist in therapists) ...[
              _TherapistRow(
                name: therapist.name,
                status: therapist.status,
                statusColor: therapist.isFree
                    ? const Color(0xFF4CAF50)
                    : const Color(0xFFF59E0B),
                done: '${therapist.doneCount} done',
              ),
              if (therapist != therapists.last)
                const Divider(height: 16, color: Color(0xFFF0F0F0)),
            ],
          ],
        ),
      ),
    );
  }
}

class _TabletOtherCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color iconBg;
  final Color iconColor;
  final VoidCallback? onTap;

  const _TabletOtherCard({
    required this.icon,
    required this.label,
    required this.iconBg,
    required this.iconColor,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: _TabletCard(
          child: Row(
            children: [
              _IconBox(icon: icon, bg: iconBg, color: iconColor),
              const SizedBox(width: 12),
              Text(label,
                style: const TextStyle(
                  fontSize: 15, fontWeight: FontWeight.w500,
                  color: Color(0xFF1A1A2E),
                )),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// PHONE LAYOUT — vertical, analytics before staff status
// ─────────────────────────────────────────────────────────────────────────────
class _PhoneLayout extends StatelessWidget {
  final _BusinessProfile profile;
  final String role;
  final bool isLoadingSettings;
  final VoidCallback onOpenSettings;

  const _PhoneLayout({
    required this.profile,
    required this.role,
    required this.isLoadingSettings,
    required this.onOpenSettings,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [

          // ── Top bar ──────────────────────────────────────────
          _PhoneTopBar(
            profile: profile,
            role: role,
            isLoadingSettings: isLoadingSettings,
            onOpenSettings: onOpenSettings,
          ),

          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [

                // ── Main section ─────────────────────────────
                const _SectionLabel('Main'),
                const SizedBox(height: 12),

                // Row 1: Appointments + Quick Book
                Row(
                  children: [
                    Expanded(child: _PhoneAppointmentCard()),
                    const SizedBox(width: 12),
                    Expanded(child: _PhoneQuickBookCard()),
                  ],
                ),
                const SizedBox(height: 12),

                // Row 2: POS + Members
                Row(
                  children: [
                    Expanded(child: _PhonePosCard()),
                    const SizedBox(width: 12),
                    Expanded(child: _PhoneCustomersCard()),
                  ],
                ),

                const SizedBox(height: 24),

                // ── Analytics section (FIRST on phone) ───────
                const _SectionLabel('Analytics'),
                const SizedBox(height: 12),
                _PhoneAnalyticsCard(),

                const SizedBox(height: 24),

                // ── Staff Status section ──────────────────────
                const _SectionLabel('Staff Status'),
                const SizedBox(height: 12),
                _PhoneStaffStatusCard(role: role),

                const SizedBox(height: 24),

                // ── Others section ────────────────────────────
                const _SectionLabel('Others'),
                const SizedBox(height: 12),
                GridView.count(
                  crossAxisCount: 2,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                  childAspectRatio: 2.2,
                  children: [
                    _PhoneOtherCard(
                      icon: Icons.history_outlined,
                      label: 'History',
                      iconBg: const Color(0xFFE8F4F8),
                      iconColor: const Color(0xFF5BA4B5),
                    ),
                    _PhoneOtherCard(
                      icon: Icons.person_outline,
                      label: 'Attendance',
                      iconBg: const Color(0xFFFFF3E0),
                      iconColor: const Color(0xFFF59E0B),
                    ),
                    _PhoneOtherCard(
                      icon: Icons.settings_outlined,
                      label: 'Settings',
                      iconBg: const Color(0xFFE8F5E9),
                      iconColor: const Color(0xFF4CAF50),
                      onTap: onOpenSettings,
                    ),
                    _PhoneOtherCard(
                      icon: Icons.bar_chart_outlined,
                      label: 'Reports',
                      iconBg: const Color(0xFFEDE7F6),
                      iconColor: const Color(0xFF7C3AED),
                    ),
                  ],
                ),

                const SizedBox(height: 24),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PhoneTopBar extends StatelessWidget {
  final _BusinessProfile profile;
  final String role;
  final bool isLoadingSettings;
  final VoidCallback onOpenSettings;

  const _PhoneTopBar({
    required this.profile,
    required this.role,
    required this.isLoadingSettings,
    required this.onOpenSettings,
  });

  void _openBusinessProfile(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (context) => _BusinessProfileDialog(profile: profile),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: () => _openBusinessProfile(context),
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
                child: Row(
                  children: [
                    Container(
                      width: 36, height: 36,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: Color(0xFF1B6B72),
                      ),
                      child: Center(
                        child: Text(profile.logoInitial,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          )),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(profile.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF1A1A2E),
                            )),
                          Text(profile.location,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 11,
                              color: Color(0xFF9E9E9E),
                            )),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          _RolePill(
            role: role,
            isLoading: isLoadingSettings,
            compact: true,
          ),
          const SizedBox(width: 8),
          const _NotificationButton(compact: true),
          const SizedBox(width: 8),
          _SettingsButton(onPressed: onOpenSettings, compact: true),
        ],
      ),
    );
  }
}

class _PhoneAppointmentCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final stats = _DashboardStats.placeholder;

    return _PhoneCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            _IconBox(
              icon: Icons.calendar_today_outlined,
              bg: const Color(0xFFE8F5E9),
              color: const Color(0xFF1B6B72),
              size: 32,
            ),
            const SizedBox(width: 8),
            const Text('Appointments',
              style: TextStyle(
                fontSize: 13, fontWeight: FontWeight.w600,
                color: Color(0xFF1A1A2E),
              )),
          ]),
          const SizedBox(height: 10),
          const Text('Total Today',
            style: TextStyle(fontSize: 11, color: Color(0xFF9E9E9E))),
          const SizedBox(height: 4),
          Text('${stats.todayAppointments}',
            style: const TextStyle(
              fontSize: 28, fontWeight: FontWeight.bold,
              color: Color(0xFF1A1A2E),
            )),
          const SizedBox(height: 4),
          Row(children: [
            Text('${stats.doneAppointments} Done  ',
              style: const TextStyle(
                fontSize: 11, color: Color(0xFF4CAF50),
                fontWeight: FontWeight.w500,
              )),
            Text('${stats.pendingAppointments} Pending',
              style: const TextStyle(
                fontSize: 11, color: Color(0xFFF59E0B),
                fontWeight: FontWeight.w500,
              )),
          ]),
        ],
      ),
    );
  }
}

class _PhoneQuickBookCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1B6B72),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36, height: 36,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.add, color: Colors.white, size: 20),
          ),
          const SizedBox(height: 12),
          const Text('Quick Book',
            style: TextStyle(
              fontSize: 15, fontWeight: FontWeight.bold,
              color: Colors.white,
            )),
          const SizedBox(height: 4),
          Text('Create new\nappointment',
            style: TextStyle(
              fontSize: 11,
              color: Colors.white.withValues(alpha: 0.85),
            )),
        ],
      ),
    );
  }
}

class _PhonePosCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final stats = _DashboardStats.placeholder;

    return _PhoneCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            _IconBox(
              icon: Icons.shopping_cart_outlined,
              bg: const Color(0xFFFFF3E0),
              color: const Color(0xFFF59E0B),
              size: 32,
            ),
            const SizedBox(width: 8),
            const Text('POS',
              style: TextStyle(
                fontSize: 13, fontWeight: FontWeight.w600,
                color: Color(0xFF1A1A2E),
              )),
          ]),
          const SizedBox(height: 10),
          const Text('Today Sales',
            style: TextStyle(fontSize: 11, color: Color(0xFF9E9E9E))),
          const SizedBox(height: 4),
          Text('RM ${stats.todaySales.toStringAsFixed(0)}',
            style: const TextStyle(
              fontSize: 20, fontWeight: FontWeight.bold,
              color: Color(0xFF1A1A2E),
            )),
          const SizedBox(height: 4),
          Text('${stats.totalTransactions} transactions',
            style: const TextStyle(fontSize: 11, color: Color(0xFF9E9E9E))),
        ],
      ),
    );
  }
}

class _PhoneCustomersCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final stats = _DashboardStats.placeholder;

    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const CustomerScreen()),
      ),
      child: _PhoneCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              _IconBox(
                icon: Icons.people_outline,
                bg: const Color(0xFFE3F2FD),
                color: const Color(0xFF1B6B72),
                size: 32,
              ),
              const SizedBox(width: 8),
              const Text('Members',
                style: TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w600,
                  color: Color(0xFF1A1A2E),
                )),
            ]),
            const SizedBox(height: 10),
            const Text('Total',
              style: TextStyle(fontSize: 11, color: Color(0xFF9E9E9E))),
            const SizedBox(height: 4),
            Text('${stats.totalCustomers}',
              style: const TextStyle(
                fontSize: 28, fontWeight: FontWeight.bold,
                color: Color(0xFF1A1A2E),
              )),
            const SizedBox(height: 4),
            Text('+${stats.newCustomersThisWeek} this week',
              style: const TextStyle(
                fontSize: 11, color: Color(0xFF1B6B72),
                fontWeight: FontWeight.w500,
              )),
          ],
        ),
      ),
    );
  }
}

class _PhoneAnalyticsCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final stats = _DashboardStats.placeholder;

    return _PhoneCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            _IconBox(
              icon: Icons.attach_money,
              bg: const Color(0xFFE8F5E9),
              color: const Color(0xFF1B6B72),
              size: 32,
            ),
            const SizedBox(width: 10),
            const Text('Revenue Summary',
              style: TextStyle(
                fontSize: 14, fontWeight: FontWeight.w600,
                color: Color(0xFF1A1A2E),
              )),
          ]),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _AnalyticsStat(
                label: 'This Week',
                value: 'RM ${stats.weekRevenue.toStringAsFixed(0)}',
              ),
              _AnalyticsStat(
                label: 'Appointments',
                value: '${stats.weekAppointments}',
              ),
              _AnalyticsStat(
                label: 'Avg. Value',
                value: 'RM ${stats.averageTransactionValue.toStringAsFixed(0)}',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PhoneStaffStatusCard extends StatelessWidget {
  final String role;

  const _PhoneStaffStatusCard({required this.role});

  @override
  Widget build(BuildContext context) {
    final therapists = _placeholderTherapists;

    return _PhoneCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Therapists Today',
                style: TextStyle(
                  fontSize: 14, fontWeight: FontWeight.w600,
                  color: Color(0xFF1A1A2E),
                )),
              GestureDetector(
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => TherapistsScreen(userRole: role),
                  ),
                ),
                child: const Text('View All',
                  style: TextStyle(
                    fontSize: 13, color: Color(0xFF1B6B72),
                    fontWeight: FontWeight.w500,
                  )),
              ),
            ],
          ),
          const SizedBox(height: 12),
          for (final therapist in therapists) ...[
            _TherapistRow(
              name: therapist.name,
              status: therapist.status,
              statusColor: therapist.isFree
                  ? const Color(0xFF4CAF50)
                  : const Color(0xFFF59E0B),
              done: '${therapist.doneCount} done',
            ),
            if (therapist != therapists.last)
              const Divider(height: 16, color: Color(0xFFF0F0F0)),
          ],
        ],
      ),
    );
  }
}

class _PhoneOtherCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color iconBg;
  final Color iconColor;
  final VoidCallback? onTap;

  const _PhoneOtherCard({
    required this.icon,
    required this.label,
    required this.iconBg,
    required this.iconColor,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: _PhoneCard(
          child: Row(
            children: [
              _IconBox(icon: icon, bg: iconBg, color: iconColor, size: 32),
              const SizedBox(width: 10),
              Text(label,
                style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w500,
                  color: Color(0xFF1A1A2E),
                )),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SHARED SMALL WIDGETS
// ─────────────────────────────────────────────────────────────────────────────

class _BusinessProfileDialog extends StatelessWidget {
  final _BusinessProfile profile;

  const _BusinessProfileDialog({required this.profile});

  @override
  Widget build(BuildContext context) {
    final email = FirebaseAuth.instance.currentUser?.email ?? 'No email';

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                    color: const Color(0xFF1E88E5),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.logout_outlined),
                    color: const Color(0xFF1E88E5),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Container(
                width: 82,
                height: 82,
                alignment: Alignment.center,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Color(0xFF1B6B72),
                ),
                child: Text(profile.logoInitial,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 32,
                    fontWeight: FontWeight.w600,
                  )),
              ),
              const SizedBox(height: 18),
              Text(profile.name,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF1A1A2E),
                )),
              const SizedBox(height: 6),
              Text(email,
                style: const TextStyle(fontSize: 14, color: Color(0xFF9E9E9E))),
              const SizedBox(height: 24),
              _BusinessProfileRow(
                icon: Icons.storefront_outlined,
                iconBg: const Color(0xFFFFF3D6),
                iconColor: const Color(0xFFF59E0B),
                label: 'Outlet',
                value: profile.location.toUpperCase(),
                showChevron: true,
              ),
              const SizedBox(height: 12),
              const _BusinessProfileRow(
                icon: Icons.description_outlined,
                iconBg: Color(0xFFE3F2FD),
                iconColor: Color(0xFF1E88E5),
                label: 'Subscription',
                value: '31/12/2026',
              ),
              const SizedBox(height: 12),
              Row(
                children: const [
                  Expanded(
                    child: _BusinessProfileRow(
                      icon: Icons.language_outlined,
                      iconBg: Color(0xFFE3F2FD),
                      iconColor: Color(0xFF1E88E5),
                      label: 'Language',
                      value: 'English',
                      compact: true,
                      showChevron: true,
                    ),
                  ),
                  SizedBox(width: 12),
                  Expanded(
                    child: _BusinessProfileRow(
                      icon: Icons.settings_outlined,
                      iconBg: Color(0xFFF1F3F6),
                      iconColor: Color(0xFF5F6B7A),
                      label: 'Version',
                      value: '1.0.0',
                      compact: true,
                    ),
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

class _BusinessProfileRow extends StatelessWidget {
  final IconData icon;
  final Color iconBg;
  final Color iconColor;
  final String label;
  final String value;
  final bool compact;
  final bool showChevron;

  const _BusinessProfileRow({
    required this.icon,
    required this.iconBg,
    required this.iconColor,
    required this.label,
    required this.value,
    this.compact = false,
    this.showChevron = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: BoxConstraints(minHeight: compact ? 60 : 58),
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 14 : 18,
        vertical: 12,
      ),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: iconBg,
              borderRadius: BorderRadius.circular(7),
            ),
            child: Icon(icon, color: iconColor, size: 18),
          ),
          SizedBox(width: compact ? 10 : 14),
          Text(label,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: Color(0xFF1A1A2E),
            )),
          const SizedBox(width: 8),
          Expanded(
            child: Text(value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
              style: const TextStyle(
                fontSize: 14,
                color: Color(0xFF8A8F98),
                fontWeight: FontWeight.w500,
              )),
          ),
          if (showChevron) ...[
            const SizedBox(width: 4),
            const Icon(
              Icons.chevron_right,
              size: 18,
              color: Color(0xFFB0B5BD),
            ),
          ],
        ],
      ),
    );
  }
}

class _RolePill extends StatelessWidget {
  final String role;
  final bool isLoading;
  final bool compact;

  const _RolePill({
    required this.role,
    this.isLoading = false,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final isAdmin = role == 'admin';
    final label = isLoading ? '...' : isAdmin ? 'Admin' : 'Staff';
    final showIcon = isLoading;

    return Container(
      height: compact ? 38 : 46,
      padding: EdgeInsets.symmetric(horizontal: compact ? 12 : 22),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xFFE0E0E0)),
        borderRadius: BorderRadius.circular(compact ? 19 : 14),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showIcon) ...[
            Icon(
              Icons.hourglass_empty_outlined,
              size: compact ? 17 : 20,
              color: const Color(0xFF1B6B72),
            ),
            SizedBox(width: compact ? 4 : 8),
          ],
          Text(label,
            style: TextStyle(
              fontSize: compact ? 12 : 16,
              fontWeight: FontWeight.w500,
              color: const Color(0xFF1A1A2E),
            )),
        ],
      ),
    );
  }
}

class _NotificationButton extends StatelessWidget {
  final bool compact;

  const _NotificationButton({this.compact = false});

  @override
  Widget build(BuildContext context) {
    final buttonSize = compact ? 38.0 : 48.0;
    final iconSize = compact ? 20.0 : 24.0;

    return InkWell(
      onTap: () {
        showDialog<void>(
          context: context,
          builder: (context) => const _NotificationDialog(),
        );
      },
      borderRadius: BorderRadius.circular(compact ? 19 : 14),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: buttonSize,
            height: buttonSize,
            decoration: BoxDecoration(
              color: compact ? const Color(0xFFC8963E) : Colors.white,
              border: compact
                  ? null
                  : Border.all(color: const Color(0xFFE0E0E0)),
              borderRadius: BorderRadius.circular(compact ? 19 : 14),
            ),
            child: Icon(
              Icons.notifications_none_outlined,
              color: compact ? Colors.white : const Color(0xFF5F6B7A),
              size: iconSize,
            ),
          ),
          Positioned(
            top: compact ? -4 : -6,
            right: compact ? -2 : -4,
            child: Container(
              width: 22,
              height: 22,
              alignment: Alignment.center,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Color(0xFFE53935),
              ),
              child: Text('${_placeholderTransactions.length}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                )),
            ),
          ),
        ],
      ),
    );
  }
}

class _NotificationDialog extends StatelessWidget {
  const _NotificationDialog();

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620, maxHeight: 680),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                    color: const Color(0xFF1E88E5),
                  ),
                  const Spacer(),
                ],
              ),
              const SizedBox(height: 4),
              Center(
                child: Container(
                  width: 82,
                  height: 82,
                  alignment: Alignment.center,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: Color(0xFFE0F3F1),
                  ),
                  child: const Icon(
                    Icons.notifications_none_outlined,
                    color: Color(0xFF1B6B72),
                    size: 38,
                  ),
                ),
              ),
              const SizedBox(height: 18),
              const Center(
                child: Text('Recent Transactions',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF1A1A2E),
                  )),
              ),
              const SizedBox(height: 6),
              Center(
                child: Text('${_placeholderTransactions.length} new transactions',
                  style: const TextStyle(
                    fontSize: 14,
                    color: Color(0xFF9E9E9E),
                  )),
              ),
              const SizedBox(height: 24),
              Flexible(
                child: ScrollConfiguration(
                  behavior: const _NoScrollbarScrollBehavior(),
                  child: ListView.separated(
                    shrinkWrap: true,
                    padding: EdgeInsets.zero,
                    itemCount: _placeholderTransactions.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 12),
                    itemBuilder: (context, index) => _TransactionTile(
                      transaction: _placeholderTransactions[index],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TransactionTile extends StatelessWidget {
  final _TransactionSummary transaction;

  const _TransactionTile({required this.transaction});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFFAFBFC),
        border: Border.all(color: const Color(0xFFE6E8EB)),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _IconBox(
            icon: Icons.shopping_cart_outlined,
            bg: const Color(0xFFE0F3F1),
            color: const Color(0xFF1B6B72),
            size: 40,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(transaction.customerName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF1A1A2E),
                  )),
                const SizedBox(height: 4),
                Text(transaction.serviceName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    color: Color(0xFF5F6B7A),
                  )),
                const SizedBox(height: 12),
                Text('${transaction.date}  -  ${transaction.time}',
                  style: const TextStyle(
                    fontSize: 14,
                    color: Color(0xFF5F6B7A),
                  )),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text('RM ${transaction.amount.toStringAsFixed(0)}',
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: Color(0xFF1B6B72),
            )),
        ],
      ),
    );
  }
}

class _NoScrollbarScrollBehavior extends ScrollBehavior {
  const _NoScrollbarScrollBehavior();

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return child;
  }
}

class _SettingsButton extends StatelessWidget {
  final VoidCallback onPressed;
  final bool compact;

  const _SettingsButton({
    required this.onPressed,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final size = compact ? 38.0 : 48.0;

    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(compact ? 19 : 14),
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: const Color(0xFF1B6B72),
          borderRadius: BorderRadius.circular(compact ? 19 : 14),
        ),
        child: Icon(
          Icons.settings_outlined,
          color: Colors.white,
          size: compact ? 20 : 24,
        ),
      ),
    );
  }
}

class _BusinessSettingsDialog extends StatefulWidget {
  final _BusinessProfile profile;
  final bool isAdmin;

  const _BusinessSettingsDialog({
    required this.profile,
    required this.isAdmin,
  });

  @override
  State<_BusinessSettingsDialog> createState() =>
      _BusinessSettingsDialogState();
}

class _BusinessSettingsDialogState extends State<_BusinessSettingsDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _locationController;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.profile.name);
    _locationController = TextEditingController(text: widget.profile.location);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _locationController.dispose();
    super.dispose();
  }

  void _save() {
    if (!widget.isAdmin) return;

    Navigator.of(context).pop(
      widget.profile.copyWith(
        name: _nameController.text.trim(),
        location: _locationController.text.trim(),
      ),
    );
  }

  Future<void> _signOut() async {
    final shouldSignOut = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Text('Log out?'),
        content: const Text('Are you sure you want to log out of this account?'),
        actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFE53935),
              foregroundColor: Colors.white,
              elevation: 0,
            ),
            child: const Text('Log Out'),
          ),
        ],
      ),
    );

    if (shouldSignOut != true || !mounted) return;

    await FirebaseAuth.instance.signOut();
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(30, 28, 30, 24),
              child: Row(
                children: [
                  const Expanded(
                    child: Text('Business Settings',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF1A1A2E),
                      )),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                    style: IconButton.styleFrom(
                      backgroundColor: const Color(0xFFF1F3F6),
                      foregroundColor: const Color(0xFF5F6B7A),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: Color(0xFFE6E8EB)),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(30, 28, 30, 30),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (!widget.isAdmin) ...[
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFF3E0),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Text(
                          'Only admins can edit business name, location, and logo.',
                          style: TextStyle(
                            fontSize: 13,
                            color: Color(0xFF8A5A00),
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      const SizedBox(height: 18),
                    ],
                    _BusinessSettingsField(
                      label: 'Business Name',
                      controller: _nameController,
                      enabled: widget.isAdmin,
                    ),
                    const SizedBox(height: 24),
                    _BusinessSettingsField(
                      label: 'Location',
                      controller: _locationController,
                      enabled: widget.isAdmin,
                    ),
                    const SizedBox(height: 24),
                    const Text('Business Logo',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF5F6B7A),
                      )),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Container(
                          width: 80,
                          height: 80,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: const Color(0xFF1B6B72),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(widget.profile.logoInitial,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 26,
                              fontWeight: FontWeight.w500,
                            )),
                        ),
                        const SizedBox(width: 20),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: widget.isAdmin ? () {} : null,
                            icon: const Icon(Icons.upload_outlined),
                            label: const Text('Upload Logo'),
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size.fromHeight(58),
                              foregroundColor: const Color(0xFF5F6B7A),
                              side: const BorderSide(color: Color(0xFFE0E0E0)),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                              textStyle: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    const Text('Recommended: Square image, min 200x200px',
                      style: TextStyle(
                        fontSize: 14,
                        color: Color(0xFF5F6B7A),
                      )),
                    const SizedBox(height: 24),
                    ElevatedButton.icon(
                      onPressed: _signOut,
                      icon: const Icon(Icons.logout_outlined),
                      label: const Text('Log Out'),
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size.fromHeight(54),
                        backgroundColor: const Color(0xFFE53935),
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                        textStyle: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const Divider(height: 1, color: Color(0xFFE6E8EB)),
            Padding(
              padding: const EdgeInsets.all(30),
              child: Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      style: TextButton.styleFrom(
                        minimumSize: const Size.fromHeight(56),
                        backgroundColor: const Color(0xFFF1F3F6),
                        foregroundColor: const Color(0xFF1A1A2E),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                        textStyle: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: widget.isAdmin ? _save : null,
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size.fromHeight(56),
                        backgroundColor: const Color(0xFF1B6B72),
                        foregroundColor: Colors.white,
                        disabledBackgroundColor: const Color(0xFFE6E8EB),
                        disabledForegroundColor: const Color(0xFF9E9E9E),
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                        textStyle: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      child: const Text('Save Changes'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BusinessSettingsField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final bool enabled;

  const _BusinessSettingsField({
    required this.label,
    required this.controller,
    required this.enabled,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: Color(0xFF5F6B7A),
          )),
        const SizedBox(height: 10),
        TextField(
          controller: controller,
          enabled: enabled,
          style: const TextStyle(fontSize: 16, color: Color(0xFF1A1A2E)),
          decoration: InputDecoration(
            filled: true,
            fillColor: enabled ? Colors.white : const Color(0xFFF6F7F8),
            disabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: Color(0xFFE0E0E0)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: Color(0xFFE0E0E0)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(
                color: Color(0xFF1B6B72),
                width: 1.5,
              ),
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 20,
              vertical: 18,
            ),
          ),
        ),
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(text,
      style: const TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: Color(0xFF1A1A2E),
      ));
  }
}

class _TabletCard extends StatelessWidget {
  final Widget child;
  const _TabletCard({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: child,
    );
  }
}

class _PhoneCard extends StatelessWidget {
  final Widget child;
  const _PhoneCard({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: child,
    );
  }
}

class _IconBox extends StatelessWidget {
  final IconData icon;
  final Color bg;
  final Color color;
  final double size;

  const _IconBox({
    required this.icon,
    required this.bg,
    required this.color,
    this.size = 38,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size, height: size,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(icon, color: color, size: size * 0.55),
    );
  }
}

class _MemberRow extends StatelessWidget {
  final String name;
  final String phone;
  const _MemberRow({required this.name, required this.phone});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(name,
          style: const TextStyle(
            fontSize: 13, fontWeight: FontWeight.w500,
            color: Color(0xFF1A1A2E),
          )),
        Text(phone,
          style: const TextStyle(fontSize: 12, color: Color(0xFF9E9E9E))),
      ],
    );
  }
}

class _AppointmentRow extends StatelessWidget {
  final String label;
  final String count;
  const _AppointmentRow({required this.label, required this.count});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label,
          style: const TextStyle(fontSize: 14, color: Color(0xFF1A1A2E))),
        Text(count,
          style: const TextStyle(
            fontSize: 20, fontWeight: FontWeight.bold,
            color: Color(0xFF1B6B72),
          )),
      ],
    );
  }
}

class _TherapistRow extends StatelessWidget {
  final String name;
  final String status;
  final Color statusColor;
  final String done;

  const _TherapistRow({
    required this.name,
    required this.status,
    required this.statusColor,
    required this.done,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        // Status dot
        Container(
          width: 8, height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: statusColor,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(name,
                style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w500,
                  color: Color(0xFF1A1A2E),
                )),
              Text(status,
                style: TextStyle(
                  fontSize: 11,
                  color: statusColor,
                  fontWeight: FontWeight.w500,
                )),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: const Color(0xFFF5F5F5),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(done,
            style: const TextStyle(
              fontSize: 11, color: Color(0xFF9E9E9E),
              fontWeight: FontWeight.w500,
            )),
        ),
      ],
    );
  }
}

class _AnalyticsStat extends StatelessWidget {
  final String label;
  final String value;
  const _AnalyticsStat({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
          style: const TextStyle(fontSize: 11, color: Color(0xFF9E9E9E))),
        const SizedBox(height: 4),
        Text(value,
          style: const TextStyle(
            fontSize: 15, fontWeight: FontWeight.bold,
            color: Color(0xFF1A1A2E),
          )),
      ],
    );
  }
}
