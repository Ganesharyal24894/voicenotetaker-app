import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';
import 'common.dart';
import 'home_icons.dart';

/// Small shared pieces of the two Home tabs and the Summarize sheets, from the
/// approved canvas (`Main`, `NotesTab`, `TodayEmpty`, `SummarizeRange`,
/// `PromptReady`). Colours and type only from `theme.dart`.

/// `rgba(109,40,217,0.14)` - the note-time chip and step-number fill.
const Color _chipFill = Color(0x246D28D9);

/// `rgba(251,113,133,0.10)` / `0.30` - the "Couldn't transcribe" pill.
const Color _roseFill = Color(0x1AFB7185);
const Color _roseBorder = Color(0x4DFB7185);

/// The two-tab bar at the bottom of Home.
class HomeTabBar extends StatelessWidget {
  const HomeTabBar({required this.index, required this.onSelect, super.key});

  static const List<String> labels = <String>['Today', 'Notes'];

  final int index;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final bottom = math.max(20.0, MediaQuery.viewPaddingOf(context).bottom);
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.screen,
        border: Border(top: BorderSide(color: AppColors.raised)),
      ),
      padding: EdgeInsets.only(bottom: bottom),
      child: Row(
        children: <Widget>[
          for (var i = 0; i < labels.length; i++)
            Expanded(
              child: Semantics(
                button: true,
                selected: i == index,
                label: '${labels[i]} tab',
                container: true,
                excludeSemantics: true,
                onTap: () => onSelect(i),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onSelect(i),
                  child: SizedBox(
                    height: 64,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: <Widget>[
                        HomeIcon(
                          i == 0 ? HomeGlyph.todaySquare : HomeGlyph.lines,
                          size: 22,
                          color: i == index ? AppColors.purpleText : AppColors.textTertiary,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          labels[i],
                          style: AppText.label13.copyWith(
                            fontSize: 12,
                            color: i == index ? AppColors.purpleText : AppColors.textTertiary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A to-do's box: 20px, 6px corners, a 44px target.
class TodoCheckbox extends StatelessWidget {
  const TodoCheckbox({
    required this.checked,
    required this.onChanged,
    required this.semanticLabel,
    super.key,
  });

  final bool checked;
  final ValueChanged<bool> onChanged;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    final instant = AppMotion.isReduced(context);
    return Semantics(
      checked: checked,
      label: semanticLabel,
      container: true,
      excludeSemantics: true,
      onTap: () => onChanged(!checked),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onChanged(!checked),
        child: SizedBox.square(
          dimension: AppShape.minTapTarget,
          child: Center(
            child: AnimatedContainer(
              duration: instant ? Duration.zero : const Duration(milliseconds: 160),
              curve: Curves.easeOut,
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                color: checked ? AppColors.primaryFill : Colors.transparent,
                borderRadius: BorderRadius.circular(6),
                border: checked ? null : Border.all(color: AppColors.textTertiary, width: 1.5),
              ),
              alignment: Alignment.center,
              child: checked
                  ? const HomeIcon(HomeGlyph.check, size: 14, color: AppColors.onPrimaryFill, strokeWidth: 2.2)
                  : null,
            ),
          ),
        ),
      ),
    );
  }
}

/// The purple `09:14` pill that opens the note an item came from.
class NoteTimeChip extends StatelessWidget {
  const NoteTimeChip({required this.label, required this.onTap, super.key});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TapTarget(
      onTap: onTap,
      semanticLabel: 'Open the note from $label',
      child: SizedBox(
        width: 56,
        height: AppShape.minTapTarget,
        child: Center(
          child: Container(
            height: 24,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: _chipFill,
              border: Border.all(color: AppColors.purpleChipBorder),
              borderRadius: AppShape.pill,
            ),
            alignment: Alignment.center,
            child: Text(
              label,
              maxLines: 1,
              style: AppText.batteryValue.copyWith(fontSize: 11, fontWeight: FontWeight.w400, color: AppColors.purpleText),
            ),
          ),
        ),
      ),
    );
  }
}

enum StatusPillTone { neutral, error }

/// A 22px status pill on a Notes row.
class StatusPill extends StatelessWidget {
  const StatusPill(this.label, {this.tone = StatusPillTone.neutral, super.key});

  final String label;
  final StatusPillTone tone;

  @override
  Widget build(BuildContext context) {
    final error = tone == StatusPillTone.error;
    return Container(
      height: 22,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: error ? _roseFill : null,
        border: Border.all(color: error ? _roseBorder : AppColors.border),
        borderRadius: AppShape.pill,
      ),
      alignment: Alignment.center,
      child: Text(
        label,
        maxLines: 1,
        style: AppText.label13.copyWith(
          fontSize: 11,
          color: error ? AppColors.recording : AppColors.textSecondary,
        ),
      ),
    );
  }
}

/// A caption row: `TO-DO  4 open` with an optional action on the right.
class HomeSectionHeader extends StatelessWidget {
  const HomeSectionHeader(this.title, {this.count, this.trailing, super.key});

  final String title;
  final String? count;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 36),
      child: Row(
        children: <Widget>[
          SectionCaption(title),
          if (count != null) ...<Widget>[
            const SizedBox(width: 8),
            Text(count!, style: AppText.meta12),
          ],
          const Spacer(),
          ?trailing,
        ],
      ),
    );
  }
}

/// A text action with an optional glyph - "Paste AI reply", "All notes",
/// "Show all 4". 44px tall.
class LinkAction extends StatelessWidget {
  const LinkAction({
    required this.label,
    required this.onTap,
    this.glyph,
    this.glyphSize = 15,
    this.glyphGap = 7,
    this.color = AppColors.purpleText,
    super.key,
  });

  final String label;
  final VoidCallback? onTap;
  final HomeGlyph? glyph;
  final double glyphSize;
  final double glyphGap;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return TapTarget(
      onTap: onTap,
      semanticLabel: label,
      child: SizedBox(
        height: AppShape.minTapTarget,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (glyph != null) ...<Widget>[
              HomeIcon(glyph!, size: glyphSize, color: color),
              SizedBox(width: glyphGap),
            ],
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.label13.copyWith(color: color),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A 46px button, filled or outlined, with a leading glyph.
class SheetButton extends StatelessWidget {
  const SheetButton({
    required this.label,
    required this.onPressed,
    this.glyph,
    this.filled = true,
    super.key,
  });

  final String label;
  final VoidCallback? onPressed;
  final HomeGlyph? glyph;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final color = filled ? AppColors.onPrimaryFill : AppColors.textSecondary;
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      container: true,
      excludeSemantics: true,
      onTap: onPressed,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: Opacity(
          opacity: enabled ? 1 : 0.45,
          child: Container(
            height: 46,
            decoration: BoxDecoration(
              color: filled ? AppColors.primaryFill : null,
              border: filled ? null : Border.all(color: AppColors.border),
              borderRadius: AppShape.control,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                if (glyph != null) ...<Widget>[
                  HomeIcon(glyph!, size: filled ? 18 : 17, color: color),
                  SizedBox(width: filled ? 10 : 9),
                ],
                Flexible(
                  child: Text(
                    label,
                    overflow: TextOverflow.ellipsis,
                    style: filled ? AppText.buttonLabel : AppText.buttonLabelQuiet,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Opens a bottom sheet in the canvas's style: card fill, a hairline on top,
/// 16px corners, a grab handle.
Future<T?> showHomeSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.card,
    barrierColor: const Color(0xB808070C),
    shape: const RoundedRectangleBorder(
      side: BorderSide(color: AppColors.border),
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (context) {
      final bottom = math.max(32.0, MediaQuery.viewPaddingOf(context).bottom);
      return SafeArea(
        top: false,
        bottom: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(AppShape.gutter, 10, AppShape.gutter, bottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: const BoxDecoration(color: AppColors.border, borderRadius: AppShape.pill),
                ),
              ),
              const SizedBox(height: 20),
              Flexible(child: builder(context)),
            ],
          ),
        ),
      );
    },
  );
}

/// Shows a short, plain message at the bottom of the screen.
void showHomeMessage(BuildContext context, String message) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        backgroundColor: AppColors.raised,
        behavior: SnackBarBehavior.floating,
        shape: const RoundedRectangleBorder(borderRadius: AppShape.control),
        content: Text(message, style: AppText.body13.copyWith(color: AppColors.textPrimary)),
      ),
    );
}

/// The app's switch, as the Always-listening card draws it.
class HomeSwitch extends StatelessWidget {
  const HomeSwitch({required this.label, required this.value, required this.onChanged, super.key});

  final String label;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: label,
      child: Switch(
        value: value,
        onChanged: onChanged,
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? AppColors.onPrimaryFill : AppColors.textSecondary,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? AppColors.primaryFill : AppColors.raised,
        ),
        trackOutlineColor: const WidgetStatePropertyAll<Color>(AppColors.border),
      ),
    );
  }
}
