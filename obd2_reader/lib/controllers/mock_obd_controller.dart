import 'dart:async';

import 'package:flutter_blue_classic/flutter_blue_classic.dart';

import 'obd_controller.dart';
import '../models/obd_sample.dart';

/// A lightweight mock controller used for desktop/web simulation builds.
class MockObdController extends ObdController {
  Timer? _simTimer;
  Timer? _monitorTimer;
  final StreamController<String> _monitorController =
      StreamController<String>.broadcast();

  @override
  Stream<String> get monitorStream => _monitorController.stream;

  @override
  Future<List<BluetoothDevice>> loadBondedDevices() async {
    return <BluetoothDevice>[];
  }

  @override
  Future<void> connectAndInitialize(BluetoothDevice device) async {
    state = ObdConnectionState.connecting;
    errorMessage = null;
    notifyListeners();
    await Future.delayed(const Duration(milliseconds: 400));
    connectedDevice = device;
    state = ObdConnectionState.initializing;
    notifyListeners();
    await Future.delayed(const Duration(milliseconds: 300));

    supportedPids = {'0C', '0D', '05', '04', '11'};
    final now = DateTime.now();
    latestByPid['0C'] = ObdSample(
        timestamp: now,
        pid: '0C',
        name: 'Engine RPM',
        rawHex: '0A F0',
        decodedValue: 1600.0,
        unit: 'rpm');
    latestByPid['0D'] = ObdSample(
        timestamp: now,
        pid: '0D',
        name: 'Vehicle Speed',
        rawHex: '1E',
        decodedValue: 30.0,
        unit: 'km/h');

    state = ObdConnectionState.polling;
    notifyListeners();

    _simTimer?.cancel();
    _simTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final t = DateTime.now();
      final rpm = (1000 + (100 * (t.second % 6))).toDouble();
      final spd = (10 + (t.second % 50)).toDouble();
      latestByPid['0C'] = ObdSample(
          timestamp: t,
          pid: '0C',
          name: 'Engine RPM',
          rawHex: '??',
          decodedValue: rpm,
          unit: 'rpm');
      latestByPid['0D'] = ObdSample(
          timestamp: t,
          pid: '0D',
          name: 'Vehicle Speed',
          rawHex: '??',
          decodedValue: spd,
          unit: 'km/h');
      log.add(latestByPid['0C']!);
      log.add(latestByPid['0D']!);
      if (log.length > 20000) log.removeRange(0, log.length - 20000);
      notifyListeners();
    });
  }

  @override
  Future<void> disconnect() async {
    _simTimer?.cancel();
    _simTimer = null;
    _monitorTimer?.cancel();
    _monitorTimer = null;
    _monitorController.add('');
    state = ObdConnectionState.disconnected;
    connectedDevice = null;
    supportedPids = {};
    latestByPid.clear();
    notifyListeners();
  }

  @override
  Future<String> sendRawCommand(String command) async {
    await Future.delayed(const Duration(milliseconds: 150));
    if (command.startsWith('AT')) return 'OK';
    // Simulate Mode 22 candidate response for a known test pattern
    if (command.contains('223086') || command.contains('22')) {
      return '41 22 08 6F';
    }
    return 'NO DATA';
  }

  @override
  Future<void> startAtmaMonitor() async {
    // Simulate ATMA by emitting pseudo-CAN frames periodically.
    _monitorTimer?.cancel();
    _monitorTimer = Timer.periodic(const Duration(milliseconds: 200), (t) {
      final now = DateTime.now();
      final msg =
          '${now.toIso8601String()}, 18FEF100, 8, 00 11 22 33 44 55 66 77';
      _monitorController.add(msg);
    });
  }

  @override
  Future<void> stopAtmaMonitor() async {
    _monitorTimer?.cancel();
    _monitorTimer = null;
    // small delay to mimic adapter reset
    await Future.delayed(const Duration(milliseconds: 150));
  }

  @override
  Future<String> testGearCandidate(
      {required String header,
      required String mode22Command,
      Duration timeout = const Duration(seconds: 3)}) async {
    await Future.delayed(const Duration(milliseconds: 200));
    // Return a plausible Mode 22 response string that UI can parse.
    return '62 ${mode22Command.substring(mode22Command.length - 2)} 03 10';
  }

  @override
  void dispose() {
    _simTimer?.cancel();
    _monitorTimer?.cancel();
    _monitorController.close();
    super.dispose();
  }
}
