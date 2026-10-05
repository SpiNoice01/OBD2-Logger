import 'dart:async';

// no model imports needed here; simulator is standalone.

/// Simple simulator that emits plausible values for Race Dash when no live
/// OBD connection is present. Designed to be lightweight and removable.
class DebugDataSimulator {
  final _rpmController = StreamController<int>.broadcast();
  final _speedController = StreamController<int>.broadcast();
  final _gearController = StreamController<int?>.broadcast();
  final _tempController = StreamController<double>.broadcast();
  final _loadController = StreamController<double>.broadcast();
  final _battController = StreamController<double>.broadcast();

  Timer? _timer;
  int _tick = 0;

  Stream<int> get rpmStream => _rpmController.stream;
  Stream<int> get speedStream => _speedController.stream;
  Stream<int?> get gearStream => _gearController.stream;
  Stream<double> get tempStream => _tempController.stream;
  Stream<double> get loadStream => _loadController.stream;
  Stream<double> get battStream => _battController.stream;

  void start({int baseRpm = 800}) {
    stop();
    _tick = 0;
    _timer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      _tick++;
      // simulate rpm as a slow triangular wave between 800 and 7000
      final phase = (_tick % 80) / 80.0; // 0..1
      final rpm =
          (800 + (7000 - 800) * (phase < 0.5 ? (phase * 2) : (2 - phase * 2)))
              .toInt();
      // speed proportional to rpm with some rounding and gear influence
      final gear = _computeGearForRpm(rpm);
      final speed = (rpm / 100 * (gear.clamp(1, 6))).toInt();
      final temp = 70 + (5 * (phase - 0.5));
      final load = 20 + 30 * (phase < 0.5 ? phase * 2 : 2 - phase * 2);
      final batt = 13.5 + 0.1 * ((phase * 2) - 1);

      _rpmController.add(rpm);
      _speedController.add(speed);
      _gearController.add(gear);
      _tempController.add(temp);
      _loadController.add(load);
      _battController.add(batt);
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
    _rpmController.close();
    _speedController.close();
    _gearController.close();
    _tempController.close();
    _loadController.close();
    _battController.close();
  }
}
