import 'package:flutter/material.dart';

import '../theme.dart';
import 'app_icons.dart';

/// A plain row at the foot of a screen: a title, a line of meta, a chevron
/// and a hairline above it. Export notes and Diagnostics are both one of
/// these, which is what makes them read as a pair rather than as two
/// unrelated buttons that happen to be adjacent.
///
/// SHARED, AND SO IN `widgets/`: the assistant's own row in Recorder settings
/// is one of these too, and it lives inside the feature
/// (`view/assistant/assistant_settings_row.dart`). Neither side owns the
/// shape.
class EndRow extends StatelessWidget {
  const EndRow({
    required this.title,
    required this.meta,
    required this.onTap,
    super.key,
  });

  final String title;
  final String meta;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: title,
      container: true,
      excludeSemantics: true,
      onTap: onTap,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: AppShape.minTapTarget),
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: AppColors.raised)),
          ),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(title, style: AppText.rowTitle),
                    const SizedBox(height: 4),
                    Text(meta, style: AppText.rowMeta),
                  ],
                ),
              ),
              const AppIcon(
                AppGlyph.chevronRight,
                size: 17,
                color: AppColors.textTertiary,
                strokeWidth: 1.7,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
