import 'package:flutter/material.dart';

import '../data/repositories/settings_repository.dart';

const _receiptBrandLogoUrl =
    'https://thebestwellness.my/pics/transparent%20logo.png';

/// Shared business identity row used by receipt details.
///
/// The logo is read from the public business settings record that is already
/// used by the dashboard. Receipt rendering remains usable if settings or the
/// image are unavailable, so a missing logo never hides the receipt itself.
class ReceiptBusinessIdentity extends StatefulWidget {
  final String label;

  const ReceiptBusinessIdentity({super.key, this.label = 'BILL RECEIPT'});

  @override
  State<ReceiptBusinessIdentity> createState() =>
      _ReceiptBusinessIdentityState();
}

class _ReceiptBusinessIdentityState extends State<ReceiptBusinessIdentity> {
  late final Future<Map<String, dynamic>?> _settingsFuture;

  @override
  void initState() {
    super.initState();
    _settingsFuture = SettingsRepository().getBusinessSettings();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<String, dynamic>?>(
      future: _settingsFuture,
      builder: (context, snapshot) {
        final settings = snapshot.data;
        final businessName = settings?['businessName']?.toString().trim() ?? '';
        final settingsLogoUrl = _safeHttpsUrl(settings?['logoUrl']);

        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _ReceiptLogo(fallbackUrl: settingsLogoUrl),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (businessName.isNotEmpty) ...[
                    Text(
                      businessName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFF1A1A2E),
                        fontSize: 12,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 3),
                  ],
                  Row(
                    children: [
                      const Icon(
                        Icons.receipt_long_outlined,
                        size: 17,
                        color: Color(0xFF1B6B72),
                      ),
                      const SizedBox(width: 7),
                      Text(
                        widget.label,
                        style: const TextStyle(
                          color: Color(0xFF1B6B72),
                          fontSize: 11,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  String _safeHttpsUrl(Object? value) {
    final raw = value?.toString().trim() ?? '';
    final uri = Uri.tryParse(raw);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return '';
    return raw;
  }
}

class _ReceiptLogo extends StatelessWidget {
  final String fallbackUrl;

  const _ReceiptLogo({required this.fallbackUrl});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Image.network(
        _receiptBrandLogoUrl,
        width: 52,
        height: 52,
        fit: BoxFit.contain,
        semanticLabel: 'Business logo',
        errorBuilder: (context, error, stackTrace) => fallbackUrl.isEmpty
            ? const _ReceiptLogoFallback()
            : Image.network(
                fallbackUrl,
                width: 52,
                height: 52,
                fit: BoxFit.contain,
                semanticLabel: 'Business logo',
                errorBuilder: (context, error, stackTrace) =>
                    const _ReceiptLogoFallback(),
              ),
        loadingBuilder: (context, child, progress) => progress == null
            ? child
            : const _ReceiptLogoFallback(),
      ),
    );
  }
}

class _ReceiptLogoFallback extends StatelessWidget {
  const _ReceiptLogoFallback();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 52,
      height: 52,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: const Color(0xFFE8F5F5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Icon(
        Icons.receipt_long_outlined,
        size: 24,
        color: Color(0xFF1B6B72),
      ),
    );
  }
}
