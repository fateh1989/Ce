import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'dart:async';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:geolocator/geolocator.dart';

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
  double _gyroZ = 0;
  double _magHeading = 0;
  double _pressureHpa = 0;
  double _gpsSpeedKmh = 0;
  double _gpsAltitude = 0;
  double _gpsHeading = 0;
  double _verticalSpeed = 0;
  double? _lastAltitude;
  DateTime? _lastGpsTime;
  double _pitchZero = 0, _rollZero = 0, _pitchTrim = 0, _rollTrim = 0;
  CameraController? _camera;
  StreamSubscription<AccelerometerEvent>? _imu;
  StreamSubscription<GyroscopeEvent>? _gyro;
  StreamSubscription<MagnetometerEvent>? _mag;
  StreamSubscription<BarometerEvent>? _baro;
  StreamSubscription<Position>? _gps;
  bool _recording = false;

  @override
  void initState() {
    super.initState();
    _openCamera();
    _startGps();
    _gyro = gyroscopeEventStream().listen((e) {
      if (!mounted) return;
      setState(() => _gyroZ = _gyroZ * .85 + e.z * .15);
    });
    _mag = magnetometerEventStream().listen((e) {
      if (!mounted) return;
      var h = math.atan2(e.y, e.x) * 180 / math.pi;
      if (h < 0) h += 360;
      setState(() => _magHeading = _magHeading * .88 + h * .12);
    });
    _baro = barometerEventStream().listen((e) {
      if (!mounted) return;
      setState(() => _pressureHpa = _pressureHpa == 0 ? e.pressure : _pressureHpa * .9 + e.pressure * .1);
    });
    _imu = accelerometerEventStream().listen((event) {
      if (!mounted) return;
      final roll = math.atan2(event.x, math.sqrt(event.y * event.y + event.z * event.z));
      final pitch = math.atan2(-event.y, math.sqrt(event.x * event.x + event.z * event.z));
      setState(() {
        _roll = _roll * .86 + roll * .14;
        _pitch = _pitch * .86 + pitch.clamp(-math.pi / 3, math.pi / 3) * .14;
      });
    });
  }

  Future<void> _startGps() async {
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) return;
      _gps = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.bestForNavigation, distanceFilter: 0),
      ).listen((p) {
        if (!mounted) return;
        final now = DateTime.now();
        var vs = _verticalSpeed;
        if (_lastAltitude != null && _lastGpsTime != null) {
          final dt = now.difference(_lastGpsTime!).inMilliseconds / 1000.0;
          if (dt > .25 && dt < 10) {
            final raw = (p.altitude - _lastAltitude!) / dt;
            vs = vs * .82 + raw.clamp(-20.0, 20.0) * .18;
          }
        }
        _lastAltitude = p.altitude;
        _lastGpsTime = now;
        setState(() {
          _gpsSpeedKmh = p.speed.isFinite ? math.max(0, p.speed * 3.6) : 0;
          _gpsAltitude = p.altitude;
          if (p.heading.isFinite && p.speed > 1.0) _gpsHeading = p.heading;
          _verticalSpeed = vs;
        });
      });
    } catch (_) {}
  }

  Future<void> _openCamera() async {
    try {
      final cams = await availableCameras();
      final back = cams.where((x) => x.lensDirection == CameraLensDirection.back);
      final selected = back.isNotEmpty ? back.first : cams.first;
      final controller = CameraController(selected, ResolutionPreset.high, enableAudio: false);
      await controller.initialize();
      if (!mounted) { await controller.dispose(); return; }
      setState(() => _camera = controller);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('الكاميرا: ' + e.toString())));
    }
  }

  void _zero() => setState(() {
    _pitchZero = _pitch; _rollZero = _roll; _pitchTrim = 0; _rollTrim = 0;
  });

  Future<void> _toggleRecord() async {
    final c = _camera;
    if (c == null || !c.value.isInitialized) return;
    try {
      if (_recording) { await c.stopVideoRecording(); } else { await c.startVideoRecording(); }
      if (mounted) setState(() => _recording = !_recording);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('التسجيل: ' + e.toString())));
    }
  }

  @override
  void dispose() {
    _imu?.cancel();
    _gyro?.cancel();
    _mag?.cancel();
    _baro?.cancel();
    _gps?.cancel();
    _camera?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pitch = _pitch - _pitchZero + _pitchTrim * math.pi / 180;
    final roll = _roll - _rollZero + _rollTrim * math.pi / 180;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(child: Stack(fit: StackFit.expand, children: [
        if (_camera?.value.isInitialized == true)
          CameraPreview(_camera!)
        else
          const Center(child: CircularProgressIndicator()),
        CustomPaint(painter: _PfdPainter(pitch: pitch, roll: roll, transparent: true, speedKmh: _gpsSpeedKmh, altitudeM: _gpsAltitude, headingDeg: _gpsSpeedKmh > 4 ? _gpsHeading : _magHeading, verticalSpeed: _verticalSpeed)),
        Positioned(top: 82, left: 0, right: 0, child: Center(child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(color: Colors.black54, border: Border.all(color: Colors.greenAccent), borderRadius: BorderRadius.circular(6)),
          child: Text('HDG ${_magHeading.toStringAsFixed(0).padLeft(3, '0')}°   BARO ${_pressureHpa == 0 ? '--' : _pressureHpa.toStringAsFixed(1)} hPa   GYRO ${_gyroZ.toStringAsFixed(2)}',
            style: const TextStyle(color: Colors.greenAccent, fontSize: 12, fontWeight: FontWeight.bold)),
        ))),
        Positioned(top: 12, left: 12, child: IconButton.filledTonal(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.arrow_back))),
        Positioned(top: 12, right: 12, child: FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: _recording ? Colors.red : Colors.black54),
          onPressed: _toggleRecord,
          icon: Icon(_recording ? Icons.stop : Icons.fiber_manual_record),
          label: Text(_recording ? 'STOP' : 'REC'),
        )),
        Positioned(bottom: 18, left: 14, child: _TrimKnob(label: 'PITCH', value: _pitchTrim, onChanged: (v) => setState(() => _pitchTrim = v))),
        Positioned(bottom: 18, right: 14, child: _TrimKnob(label: 'ROLL', value: _rollTrim, onChanged: (v) => setState(() => _rollTrim = v))),
        Positioned(bottom: 25, left: 0, right: 0, child: Center(child: FilledButton.tonalIcon(
          onPressed: _zero, icon: const Icon(Icons.center_focus_strong), label: const Text('ZERO'),
        ))),
      ])),
    );
  }

}

class _TrimKnob extends StatelessWidget {
  final String label;
  final double value;
  final ValueChanged<double> onChanged;
  const _TrimKnob({required this.label, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) => GestureDetector(
    onVerticalDragUpdate: (d) => onChanged((value - d.delta.dy * .12).clamp(-15.0, 15.0)),
    onDoubleTap: () => onChanged(0),
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      Container(width: 62, height: 62, decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.black54, border: Border.all(color: Colors.greenAccent, width: 2)),
        child: Transform.rotate(angle: value * math.pi / 30, child: const Icon(Icons.expand_less, color: Colors.greenAccent, size: 30))),
      const SizedBox(height: 3),
      Text(label + '  ' + value.toStringAsFixed(1) + '°', style: const TextStyle(color: Colors.greenAccent, fontSize: 11, fontWeight: FontWeight.bold)),
    ]),
  );
}

class _PfdPainter extends CustomPainter {
  final double pitch;
  final double roll;
  final bool transparent;
  final double speedKmh, altitudeM, headingDeg, verticalSpeed;
  _PfdPainter({required this.pitch, required this.roll, this.transparent = false, this.speedKmh = 0, this.altitudeM = 0, this.headingDeg = 0, this.verticalSpeed = 0});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(-roll);

    final pitchPx = pitch * size.height / 1.15;
    final sky = Paint()..color = transparent ? Colors.transparent : const Color(0xFF1676B8);
    final ground = Paint()..color = transparent ? Colors.transparent : const Color(0xFF7A482A);
    final horizon = Paint()
      ..color = transparent ? Colors.greenAccent : Colors.white
      ..strokeWidth = 2;

    canvas.drawRect(Rect.fromLTRB(-size.width, -size.height * 2 + pitchPx, size.width, pitchPx), sky);
    canvas.drawRect(Rect.fromLTRB(-size.width, pitchPx, size.width, size.height * 2 + pitchPx), ground);
    canvas.drawLine(Offset(-size.width, pitchPx), Offset(size.width, pitchPx), horizon);

    final thin = Paint()
      ..color = transparent ? Colors.greenAccent : Colors.white70
      ..strokeWidth = 1.5;
    final text = TextPainter(textDirection: TextDirection.ltr);
    for (int deg = -30; deg <= 30; deg += 10) {
      if (deg == 0) continue;
      final y = pitchPx - deg * size.height / 90;
      canvas.drawLine(Offset(-45, y), Offset(45, y), thin);
      text.text = TextSpan(text: deg.abs().toString(), style: TextStyle(color: transparent ? Colors.greenAccent : Colors.white, fontSize: 12));
      text.layout();
      text.paint(canvas, Offset(52, y - text.height / 2));
      text.paint(canvas, Offset(-52 - text.width, y - text.height / 2));
    }
    canvas.restore();

    final fixed = Paint()
      ..color = transparent ? Colors.greenAccent : Colors.amber
      ..strokeWidth = 4
      ..style = PaintingStyle.stroke;
    canvas.drawLine(Offset(center.dx - 65, center.dy), Offset(center.dx - 15, center.dy), fixed);
    canvas.drawLine(Offset(center.dx + 15, center.dy), Offset(center.dx + 65, center.dy), fixed);
    canvas.drawLine(Offset(center.dx, center.dy - 8), Offset(center.dx, center.dy + 12), fixed);

    final border = Paint()
      ..color = transparent ? Colors.greenAccent : Colors.white70
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final r = math.min(size.width * .28, 115.0);
    canvas.drawArc(Rect.fromCircle(center: center, radius: r), math.pi * 1.15, math.pi * .7, false, border);

    _box(canvas, const Offset(10, 18), 'SPD', speedKmh.toStringAsFixed(0), 'km/h');
    _box(canvas, Offset(size.width - 92, 18), 'ALT', altitudeM.toStringAsFixed(0), 'm');
    _box(canvas, Offset(size.width / 2 - 42, size.height - 72), 'HDG', headingDeg.toStringAsFixed(0).padLeft(3, '0'), '°');
    _box(canvas, Offset(size.width - 92, size.height / 2 - 28), 'V/S', verticalSpeed.toStringAsFixed(1), 'm/s');
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
  bool shouldRepaint(covariant _PfdPainter oldDelegate) => oldDelegate.pitch != pitch || oldDelegate.roll != roll || oldDelegate.speedKmh != speedKmh || oldDelegate.altitudeM != altitudeM || oldDelegate.headingDeg != headingDeg || oldDelegate.verticalSpeed != verticalSpeed;
}
