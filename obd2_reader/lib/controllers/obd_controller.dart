import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_classic/flutter_blue_classic.dart';

import '../models/obd_pid.dart';
import '../models/obd_sample.dart';
import '../services/data_exporter.dart';
import '../services/obd_bluetooth_service.dart';
import '../services/obd_parser.dart';

enum ObdConnectionState {
  disconnected,
  connecting,
  initializing,
  discoveringPids,
  ready,
  polling,
  error,
}

/// Menghubungkan UI dengan [ObdBluetoothService]: mengatur alur
/// connect -> init ELM327 -> deteksi PID -> polling berulang, menyimpan
/// nilai terbaru tiap PID untuk ditampilkan live, dan menyimpan seluruh
/// riwayat sample untuk diexport.
class ObdController extends ChangeNotifier {
  final ObdBluetoothService _service = ObdBluetoothService();

  // File for session CSV autosave (null when autosave disabled).
  File? _sessionFile;

  static const int _maxLogEntries = 20000;

  ObdConnectionState state = ObdConnectionState.disconnected;
  String? errorMessage;
  BluetoothDevice? connectedDevice;
  Set<String> supportedPids = {};
  final Map<String, ObdSample> latestByPid = {};
  final List<ObdSample> log = [];

  /// Optional gear detection value. UI can read this; logic to populate
  /// it can be added later when a working Mode 22 candidate is confirmed.
  int? get currentGear => null;

  bool _pollingActive = false;
  // Nomor generasi loop polling. Setiap kali start/stop dipanggil, nomor ini
  // berubah, supaya loop lama yang mungkin masih "nyangkut" di tengah await
  // (sendCommand/delay) tidak ikut lanjut lagi kalau _pollingActive sempat
  // balik true karena resume yang datang lebih cepat dari loop lama berhenti.
  int _pollGeneration = 0;

  Future<List<BluetoothDevice>> loadBondedDevices() =>
      _service.getBondedDevices();

  Future<void> connectAndInitialize(BluetoothDevice device) async {
    try {
      state = ObdConnectionState.connecting;
      errorMessage = null;
      notifyListeners();

      await _service.connect(device);
      connectedDevice = device;

      state = ObdConnectionState.initializing;
      notifyListeners();
      await _service.initializeElm327();

      state = ObdConnectionState.discoveringPids;
      notifyListeners();
      supportedPids = await _service.discoverSupportedPids();

      // Kalau deteksi PID gagal/kosong (beberapa klon ELM327 murah tidak
      // selalu patuh), tetap coba beberapa PID inti yang paling umum
      // didukung supaya dashboard tidak kosong total.
      if (supportedPids.isEmpty) {
        supportedPids = {'0C', '0D', '05', '04', '11'};
      }

      state = ObdConnectionState.ready;
      notifyListeners();
      _startPolling();
      // Start a session CSV file to persist samples as they arrive.
      unawaited(_startSessionLogging());
    } catch (e) {
      errorMessage = e.toString();
      state = ObdConnectionState.error;
      notifyListeners();
    }
  }

  void _startPolling() {
    _pollingActive = true;
    final myGeneration = ++_pollGeneration;
    state = ObdConnectionState.polling;
    notifyListeners();
    unawaited(_pollLoop(myGeneration));
  }

  void stopPolling() {
    _pollingActive = false;
    _pollGeneration++; // Membatalkan loop yang sedang berjalan (kalau ada).
    if (state == ObdConnectionState.polling) {
      state = ObdConnectionState.ready;
      notifyListeners();
    }
  }

  void resumePolling() {
    if (!_pollingActive && connectedDevice != null) {
      _startPolling();
    }
  }

  // Prioritas polling. Satu request ke ELM327 butuh ~150-200 ms, jadi kalau
  // semua PID digilir rata, RPM hanya terbaru ~2 detik sekali (terlalu lambat
  // untuk shift light). Pola slot sekarang:
  //   RPM, speed, RPM, PID lain, RPM, speed, RPM, PID lain, ...
  // -> RPM ~3x/detik, speed ~1.5x/detik, PID lain (suhu, voltase, dll)
  //    bergiliran di slot sisanya.
  static const String _fastPid = '0C'; // RPM
  static const String _mediumPid = '0D'; // speed
  // PID yang nilainya hampir tidak berubah: cukup dibaca sesekali.
  static const Set<String> _rarePids = {'21', '33'};
  static const Duration _rarePollInterval = Duration(seconds: 30);

  Future<void> _pollLoop(int generation) async {
    bool alive() => _pollingActive && generation == _pollGeneration;

    final slowQueue = <String>[];
    DateTime? lastRarePoll;
    var slot = 0;

    while (alive()) {
      final hasRpm = supportedPids.contains(_fastPid);
      final hasSpeed = supportedPids.contains(_mediumPid);

      String? pid;
      if (hasRpm && slot.isEven) {
        pid = _fastPid;
      } else if (hasSpeed && slot % 4 == 1) {
        pid = _mediumPid;
      } else {
        if (slowQueue.isEmpty) {
          // Satu putaran PID lambat selesai: susun ulang antreannya.
          final now = DateTime.now();
          final rareDue = lastRarePoll == null ||
              now.difference(lastRarePoll) >= _rarePollInterval;
          if (rareDue) lastRarePoll = now;
          slowQueue.addAll(supportedPids
              .where((p) =>
                  p != _fastPid &&
                  p != _mediumPid &&
                  (rareDue || !_rarePids.contains(p)) &&
                  findPidDef(p) != null)
              .toList()
            ..sort());
        }
        if (slowQueue.isNotEmpty) pid = slowQueue.removeAt(0);
      }
      slot++;

      if (pid == null) {
        // Tidak ada PID untuk slot ini. Kalau memang tidak ada PID sama
        // sekali, beri jeda supaya loop tidak berputar tanpa henti.
        if (!hasRpm && !hasSpeed) {
          await Future.delayed(const Duration(milliseconds: 150));
        }
        continue;
      }

      final ok = await _pollPid(pid);
      // Jeda singkat setelah gagal (mis. koneksi putus) supaya tidak spin.
      if (!ok) await Future.delayed(const Duration(milliseconds: 100));
    }
  }

  /// Minta satu PID Mode 01, simpan hasilnya. Return false kalau gagal/timeout.
  Future<bool> _pollPid(String pid) async {
    final def = findPidDef(pid);
    if (def == null) return true; // Belum ada rumus decode untuk PID ini.

    try {
      final response = await _service.sendCommand(
        '01$pid',
        timeout: const Duration(seconds: 2),
      );
      final bytes = ObdParser.extractDataBytes(
        response,
        expectedMode: '41',
        expectedPid: pid,
      );

      final sample = ObdSample(
        timestamp: DateTime.now(),
        pid: pid,
        name: def.name,
        rawHex: bytes != null
            ? bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')
            : response.trim(),
        decodedValue: (bytes != null && bytes.length >= def.expectedBytes)
            ? def.decode(bytes)
            : null,
        unit: def.unit,
      );

      latestByPid[pid] = sample;
      log.add(sample);
      // Append sample to session CSV if enabled (fire-and-forget).
      if (_sessionFile != null) {
        unawaited(DataExporter.appendSample(_sessionFile!, sample));
      }
      if (log.length > _maxLogEntries) {
        log.removeRange(0, log.length - _maxLogEntries);
      }
      notifyListeners();
      return true;
    } catch (_) {
      // Satu PID gagal/timeout dilewati saja, lanjut ke PID berikutnya
      // supaya satu ECU yang lambat tidak macetkan seluruh polling.
      return false;
    }
  }

  Future<String> sendRawCommand(String command) {
    return _service.sendCommand(command, timeout: const Duration(seconds: 5));
  }

  Future<void> disconnect() async {
    _pollingActive = false;
    _pollGeneration++;
    await _service.disconnect();
    state = ObdConnectionState.disconnected;
    connectedDevice = null;
    supportedPids = {};
    latestByPid.clear();
    // Stop session logging (no further appends); file remains on device.
    _sessionFile = null;
    notifyListeners();
  }

  /// Pause the normal PID polling loop. Useful before running experiments
  /// that send custom headers/commands to the adapter.
  void pausePollingForExperiment() {
    _pollingActive = false;
    _pollGeneration++;
    if (state == ObdConnectionState.polling) {
      state = ObdConnectionState.ready;
      notifyListeners();
    }
  }

  /// Resume polling after an experiment.
  void resumePollingAfterExperiment() {
    if (!_pollingActive && connectedDevice != null) {
      _startPolling();
    }
  }

  /// Test a single gear candidate: set header, send mode22 command, return raw
  /// response. This uses the service command queue so ordering is preserved.
  Future<String> testGearCandidate({
    required String header,
    required String mode22Command,
    Duration timeout = const Duration(seconds: 3),
  }) async {
    // Pause regular polling while running experiment to avoid interleaving.
    pausePollingForExperiment();
    try {
      await _service.setHeader(header);
      final resp = await _service.sendCommand(mode22Command, timeout: timeout);
      return resp.trim();
    } finally {
      // Restore header and re-init so normal polling continues safely.
      await _service.resetHeaderAndInitialize();
      resumePollingAfterExperiment();
    }
  }

  /// Poll a candidate periodically; returns a cancel function to stop polling.
  Future<Function()> startPeriodicGearPolling({
    required String header,
    required String mode22Command,
    Duration interval = const Duration(seconds: 1),
    void Function(String rawResponse)? onData,
  }) async {
    var active = true;
    // Run a loop in background
    unawaited(() async {
      while (active) {
        try {
          final resp = await testGearCandidate(
              header: header, mode22Command: mode22Command);
          if (!active) break;
          if (onData != null) onData(resp);
        } catch (_) {
          // ignore
        }
        var waited = 0;
        while (active && waited < interval.inMilliseconds) {
          await Future.delayed(const Duration(milliseconds: 100));
          waited += 100;
        }
      }
    }());

    return () {
      active = false;
    };
  }

  Future<void> _startSessionLogging() async {
    try {
      _sessionFile = await DataExporter.createSessionCsv();
    } catch (_) {
      // Ignore failures to create session file; logging will remain in-memory.
    }
  }

  // --- Monitor (ATMA) helpers exposed to UI ---
  Stream<String> get monitorStream => _service.monitorStream;

  Future<void> startAtmaMonitor() async {
    pausePollingForExperiment();
    await _service.startAtmaMonitor();
    notifyListeners();
  }

  Future<void> stopAtmaMonitor() async {
    await _service.stopAtmaMonitor();
    resumePollingAfterExperiment();
    notifyListeners();
  }

  /// Public API to start session logging manually. Creates a new session CSV
  /// file and returns true if successful.
  Future<bool> startSessionLogging() async {
    try {
      await _startSessionLogging();
      notifyListeners();
      return _sessionFile != null;
    } catch (_) {
      return false;
    }
  }

  /// Stop session logging (no further appends). File remains on device.
  void stopSessionLogging() {
    _sessionFile = null;
    notifyListeners();
  }

  /// Whether a session file currently exists and is being appended to.
  bool get isSessionRecording => _sessionFile != null;

  /// Share the current session CSV file via platform share sheet.
  /// Returns true if a file was shared, false if no session file exists.
  Future<bool> shareSessionFile() async {
    final file = _sessionFile;
    if (file == null) return false;
    try {
      await DataExporter.shareFile(file);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> exportAndShareJson() async {
    final file = await DataExporter.exportJson(log);
    await DataExporter.shareFile(file);
  }

  Future<void> exportAndShareCsv() async {
    final file = await DataExporter.exportCsv(log);
    await DataExporter.shareFile(file);
  }

  @override
  void dispose() {
    _pollingActive = false;
    _service.dispose();
    super.dispose();
  }
}
