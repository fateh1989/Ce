import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:sensors_plus/sensors_plus.dart';

/// Lightweight EFIS/PFD for MUQATIL.
/// Uses the phone IMU for the artificial horizon. Navigation values will be
/// connected to MUQATIL telemetry incrementally after this visual/IMU test.
class EfisViewer extends StatefulWidget {
  const EfisViewer({super.key});

  @override
  State<EfisViewer> createState() => _EfisViewerState();
}

class _EfisViewerState extends State<EfisViewer> {
  double _pitch = 0;
  double _roll = 0;

  @override
  void initState() {
    super.initState();
    accelerometerEventStream().listen((event) {
      if (!mounted) return;
      final roll = math.atan2(event.x, math.sqrt(event.y * event.y + event.z * event.z));
      final pitch = math.atan2(-event.y, math.sqrt(event.x * event.x + event.z * event.z));
      setState(() {
        _roll = roll;
        _pitch = pitch.clamp(-math.pi / 3, math.pi / 3);
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('EFIS'),
        actions: const [
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 12),
            child: Center(child: Text('تجريبي', style: TextStyle(color: Colors.amber))),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: LayoutBuilder(
                builder: (context, c) => CustomPaint(
                  size: Size(c.maxWidth, c.maxHeight),
                  painter: _PfdPainter(pitch: _pitch, roll: _roll),
                ),
              ),
            ),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
              color: const Color(0xFF151515),
              child: const Text(
                'الأفق الاصطناعي يعمل بحساسات الهاتف — السرعة والارتفاع والاتجاه سنربطها ببيانات مقاتل بعد اختبار هذه الصفحة.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: Colors.white70),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PfdPainter extends CustomPainter {
  final double pitch;
  final double roll;
  _PfdPainter({required this.pitch, required this.roll});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(-roll);

    final pitchPx = pitch * size.height / 1.15;
    final sky = Paint()..color = const Color(0xFF1676B8);
    final ground = Paint()..color = const Color(0xFF7A482A);
    final horizon = Paint()
      ..color = Colors.white
      ..strokeWidth = 3;

    canvas.drawRect(Rect.fromLTRB(-size.width, -size.height * 2 + pitchPx, size.width, pitchPx), sky);
    canvas.drawRect(Rect.fromLTRB(-size.width, pitchPx, size.width, size.height * 2 + pitchPx), ground);
    canvas.drawLine(Offset(-size.width, pitchPx), Offset(size.width, pitchPx), horizon);

    final thin = Paint()
      ..color = Colors.white70
      ..strokeWidth = 1.5;
    final text = TextPainter(textDirection: TextDirection.ltr);
    for (int deg = -30; deg <= 30; deg += 10) {
      if (deg == 0) continue;
      final y = pitchPx - deg * size.height / 90;
      canvas.drawLine(Offset(-45, y), Offset(45, y), thin);
      text.text = TextSpan(text: deg.abs().toString(), style: const TextStyle(color: Colors.white, fontSize: 12));
      text.layout();
      text.paint(canvas, Offset(52, y - text.height / 2));
      text.paint(canvas, Offset(-52 - text.width, y - text.height / 2));
    }
    canvas.restore();

    final fixed = Paint()
      ..color = Colors.amber
      ..strokeWidth = 4
      ..style = PaintingStyle.stroke;
    canvas.drawLine(Offset(center.dx - 65, center.dy), Offset(center.dx - 15, center.dy), fixed);
    canvas.drawLine(Offset(center.dx + 15, center.dy), Offset(center.dx + 65, center.dy), fixed);
    canvas.drawLine(Offset(center.dx, center.dy - 8), Offset(center.dx, center.dy + 12), fixed);

    final border = Paint()
      ..color = Colors.white70
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final r = math.min(size.width * .28, 115.0);
    canvas.drawArc(Rect.fromCircle(center: center, radius: r), math.pi * 1.15, math.pi * .7, false, border);

    _box(canvas, const Offset(10, 18), 'SPD', '--', 'km/h');
    _box(canvas, Offset(size.width - 92, 18), 'ALT', '--', 'm');
    _box(canvas, Offset(size.width / 2 - 42, size.height - 72), 'HDG', '---', '°');
  }

  void _box(Canvas canvas, Offset p, String title, String value, String unit) {
    final rect = RRect.fromRectAndRadius(Rect.fromLTWH(p.dx, p.dy, 82, 56), const Radius.circular(5));
    canvas.drawRRect(rect, Paint()..color = Colors.black.withValues(alpha: .72));
    canvas.drawRRect(rect, Paint()..color = Colors.white54..style = PaintingStyle.stroke);
    final tp = TextPainter(textDirection: TextDirection.ltr);
    tp.text = TextSpan(text: '$title  $unit\n$value', style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold));
    tp.layout();
    tp.paint(canvas, Offset(p.dx + 7, p.dy + 7));
  }

  @override
  bool shouldRepaint(covariant _PfdPainter oldDelegate) => oldDelegate.pitch != pitch || oldDelegate.roll != roll;
}
