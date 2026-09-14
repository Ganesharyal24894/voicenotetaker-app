import 'package:flutter/material.dart';

import '../controller/app_controller.dart';
import '../model/battery_history.dart';
import '../model/battery_report.dart';
import 'battery_copy.dart';
import 'theme.dart';
import 'widgets/common.dart';
import 'widgets/home_widgets.dart';

/// The Diagnostics battery card - `BatteryHistory.dc.html`.
///
/// Percentage and time on battery, this charge as a line, when it was
/// unplugged, and a runtime estimate only once enough of the battery has been
/// used for it to mean something. The copy is [BatteryCopy]'s.
class BatteryCard extends StatelessWidget {
  const BatteryCard({required this.controller, this.now, super.key});

  final AppController controller;

  /// Relative times are worked out from this; the wall clock when null.
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final report = controller.batteryReport;
    final now = (this.now ?? DateTime.now()).toUtc();
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Row(
            children: <Widget>[
              Expanded(child: SectionCaption('Battery', small: true)),
              InfoButton(title: 'Battery', body: BatteryCopy.info),
            ],
          ),
          const SizedBox(height: 6),
          if (report == null)
            Text(_unavailable(), style: AppText.body13)
          else
            ..._report(report, now),
        ],
      ),
    );
  }

  String _unavailable() {
    if (!controller.isConnected) return BatteryCopy.notConnected;
    return switch (controller.batteryHistoryStatus) {
      BatteryHistoryStatus.notSupported => BatteryCopy.notSupported,
      BatteryHistoryStatus.unreadable => BatteryCopy.unreadable,
      _ => BatteryCopy.reading,
    };
  }

  List<Widget> _report(BatteryReport report, DateTime now) {
    final unplugged = BatteryCopy.unplugged(report, now);
    final chart = report.chart;
    return <Widget>[
      Text.rich(
        TextSpan(
          children: <InlineSpan>[
            TextSpan(
              text: BatteryCopy.percent(report.currentPercent),
              style: AppText.rowTitle,
            ),
            TextSpan(text: BatteryCopy.headlineDetail(report), style: AppText.body13),
          ],
        ),
      ),
      if (report.onBattery) ...<Widget>[
        if (chart.length >= 2) ...<Widget>[
          const SizedBox(height: 14),
          BatteryChart(points: chart, now: now),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              Text(BatteryCopy.chartLabel(chart.first, now), style: AppText.footnote11),
              Text(BatteryCopy.chartLabel(chart.last, now), style: AppText.footnote11),
            ],
          ),
        ],
        if (unplugged != null) ...<Widget>[
          const SizedBox(height: 14),
          _Row(label: 'Unplugged', value: unplugged),
        ],
        const SizedBox(height: 12),
        _Row(label: 'Estimated runtime', value: BatteryCopy.estimate(report)),
        const SizedBox(height: 12),
        Text(
          report.lowTrust
              ? '${BatteryCopy.footnote} ${BatteryCopy.partlyRecorded}'
              : BatteryCopy.footnote,
          style: AppText.footnote11,
        ),
      ],
    ];
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(label, style: AppText.devLabel),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.right,
            style: AppText.devValue.copyWith(fontWeight: FontWeight.w400),
          ),
        ),
      ],
    );
  }
}

/// This charge as a thin line: percent over time, the latest point marked.
class BatteryChart extends StatelessWidget {
  const BatteryChart({required this.points, required this.now, super.key});

  final List<BatteryPoint> points;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: 'Battery over this charge, from '
          '${points.first.percent}% to ${points.last.percent}%',
      child: SizedBox(
        height: 64,
        width: double.infinity,
        child: CustomPaint(painter: _ChartPainter(points)),
      ),
    );
  }
}

class _ChartPainter extends CustomPainter {
  _ChartPainter(this.points);

  final List<BatteryPoint> points;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawLine(
      Offset(0, size.height),
      Offset(size.width, size.height),
      Paint()
        ..color = AppColors.raised
        ..strokeWidth = 1,
    );
    final start = points.first.at;
    final span = points.last.at.difference(start).inSeconds;
    if (span <= 0) return;
    var low = 100;
    for (final p in points) {
      if (p.percent < low) low = p.percent;
    }
    // From 100% down to a little under the lowest point, in steps of ten, so
    // a small drop is visible and a big one still fits.
    final floor = ((low - 10) ~/ 10 * 10).clamp(0, 90);
    Offset at(BatteryPoint p) => Offset(
          size.width * p.at.difference(start).inSeconds / span,
          size.height * (100 - p.percent.clamp(floor, 100)) / (100 - floor),
        );
    final path = Path()..moveTo(at(points.first).dx, at(points.first).dy);
    for (final p in points.skip(1)) {
      path.lineTo(at(p).dx, at(p).dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = AppColors.purple400
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawCircle(at(points.last), 3, Paint()..color = AppColors.purple400);
  }

  @override
  bool shouldRepaint(_ChartPainter oldDelegate) => oldDelegate.points != points;
}

/// Past charges, newest first, with "Ran flat" and "Power lost" called out.
/// Hidden until the recorder has finished at least one charge.
class LastChargesCard extends StatelessWidget {
  const LastChargesCard({required this.sessions, super.key});

  final List<PastSession> sessions;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const SectionCaption('Last charges', small: true),
          const SizedBox(height: 6),
          for (final session in sessions)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 12),
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: AppColors.raised)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          BatteryCopy.sessionTitle(session),
                          style: AppText.label13.copyWith(color: AppColors.textPrimary),
                        ),
                      ),
                      if (BatteryCopy.sessionPill(session) case final pill?)
                        session.endReason == SessionEndReason.empty
                            ? _AmberPill(pill)
                            : StatusPill(pill),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(BatteryCopy.sessionMeta(session), style: AppText.footnote11),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _AmberPill extends StatelessWidget {
  const _AmberPill(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 22,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: AppColors.warningBadgeFill,
        border: Border.all(color: AppColors.warningBadgeBorder),
        borderRadius: AppShape.pill,
      ),
      alignment: Alignment.center,
      child: Text(
        label,
        style: AppText.label13.copyWith(fontSize: 11, color: AppColors.warning),
      ),
    );
  }
}
