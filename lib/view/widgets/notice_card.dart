import 'package:flutter/widgets.dart';

import '../theme.dart';
import 'common.dart';

/// The card that sits under the header on Today: an icon, what is going on,
/// one line of why, and the one thing to do about it.
///
/// Privacy mode wears it with a purple edge (`PrivacyBanner`); a recorder that
/// is not connected wears it with an amber one (`ConnectBanner`). They never
/// show together - privacy mode needs a live link - so they share one slot.
class NoticeCard extends StatelessWidget {
  const NoticeCard({
    required this.icon,
    required this.title,
    required this.meta,
    required this.action,
    required this.onAction,
    this.borderColor = AppColors.purpleChipBorder,
    super.key,
  });

  final Widget icon;
  final String title;
  final String meta;

  /// The button's label, which is also what a screen reader says for it.
  final String action;
  final VoidCallback onAction;
  final Color borderColor;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppShape.gutter, 0, AppShape.gutter, 14),
      child: AppCard(
        borderColor: borderColor,
        padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
        child: Row(
          children: <Widget>[
            icon,
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(title, style: AppText.rowTitle),
                  const SizedBox(height: 3),
                  Text(
                    meta,
                    style: AppText.rowMeta.copyWith(color: AppColors.textSecondary),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            _ActionButton(label: action, onTap: onAction),
          ],
        ),
      ),
    );
  }
}

/// A 44 px primary pill that sizes to its label.
class _ActionButton extends StatelessWidget {
  const _ActionButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      onTap: onTap,
      container: true,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          height: AppShape.minTapTarget,
          padding: const EdgeInsets.symmetric(horizontal: 18),
          alignment: Alignment.center,
          decoration: const BoxDecoration(
            color: AppColors.primaryFill,
            borderRadius: BorderRadius.all(Radius.circular(22)),
          ),
          child: Text(label, style: AppText.buttonLabel.copyWith(fontSize: 14)),
        ),
      ),
    );
  }
}
