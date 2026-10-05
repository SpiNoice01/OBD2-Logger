import 'dart:async';

/// Satu frame data simulasi: nilai per PID Mode 01 (kunci sama seperti
/// `ObdController.latestByPid`, mis. '0C' = RPM) plus gear.
class DebugFrame {
  const DebugFrame(this.pids, this.gear);

  final Map<String, double> pids;
  final int? gear;
}

/// Simple simulator that emits plausible values for Race Dash when no live
/// OBD connection is present. Designed to be lightweight and removable.
class DebugDataSimulator {
  final _controller = StreamController<DebugFrame>.broadcast();

  Timer? _timer;
  int _tick = 0;

  Stream<DebugFrame> get frames => _controller.stream;

  void start() {
    stop();
    _tick = 0;
    _timer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      _tick++;
      // simulate rpm as a slow triangular wave between 800 and 7000
      final phase = (_tick % 80) / 80.0; // 0..1
      final tri = phase < 0.5 ? phase * 2 : 2 - phase * 2; // 0..1..0
      final rpm = 800 + (7000 - 800) * tri;
      // speed proportional to rpm with some rounding and gear influence
      final gear = _computeGearForRpm(rpm.toInt());
      final speed = (rpm / 100 * gear.clamp(1, 6)).floorToDouble();

      _controller.add(DebugFrame({
        '0C': rpm.floorToDouble(),
        '0D': speed,
        '05': 70 + 5 * (phase - 0.5), // coolant
        '0F': 45 + 8 * tri, // intake air temp
        '04': 20 + 30 * tri, // engine load
        '11': 15 + 70 * tri, // throttle
        '0B': 30 + 68 * tri, // MAP (kPa)
        '33': 100, // baro (kPa)
        '42': 13.5 + 0.1 * ((phase * 2) - 1), // voltage
      }, gear));
    });
  }

  int _computeGearForRpm(int rpm) {
    // naive mapping: lower rpm -> lower gear
    if (rpm < 1500) return 1;
    if (rpm < 2500) return 2;
    if (rpm < 3500) return 3;
    if (rpm < 4500) return 4;
    return 5;
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void dispose() {
    stop();
    _controller.close();
  }
}
