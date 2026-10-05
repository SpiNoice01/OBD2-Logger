import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_blue_classic/flutter_blue_classic.dart';

import 'obd_parser.dart';

/// Lapisan komunikasi mentah ke dongle ELM327 lewat Bluetooth Classic (SPP).
///
/// Tanggung jawabnya cuma tiga: buka/tutup koneksi, mengirim satu command
/// dan menunggu satu balasan penuh (sampai ketemu prompt '>'), dan
/// menyediakan helper inisialisasi ELM327 + deteksi PID yang didukung mobil.
/// Semua logic decode nilai fisik (RPM, suhu, dst) ada di layer lain
/// (obd_pid.dart) supaya kelas ini tetap fokus ke urusan transport saja.
class ObdBluetoothService {
  final FlutterBlueClassic _blueClassic = FlutterBlueClassic();

  BluetoothConnection? _connection;
  StreamSubscription<Uint8List>? _inputSub;
  final StreamController<String> _responseController =
      StreamController<String>.broadcast();
  final StreamController<String> _monitorController =
      StreamController<String>.broadcast();
  final StringBuffer _rxBuffer = StringBuffer();
  final StringBuffer _monitorRxBuffer = StringBuffer();

  // Antrian sederhana supaya command dikirim satu-satu secara berurutan.
  // ELM327 itu half-duplex: kalau dua command dikirim bersamaan, responsnya
  // akan bercampur dan tidak bisa dipisahkan lagi.
  Future<void> _commandQueue = Future.value();
  // When true, the service is in ATMA "monitor all" mode and should
  // emit raw lines via [_monitorController] instead of accumulating
  // responses waiting for a prompt '>'
  bool _monitoring = false;
  Completer<void>? _monitorStopCompleter;

  Stream<String> get rawResponses => _responseController.stream;
  Stream<String> get monitorStream => _monitorController.stream;

  bool get isConnected => _connection?.isConnected ?? false;

  Future<bool> get isBluetoothSupported => _blueClassic.isSupported;
  Future<bool> get isBluetoothEnabled => _blueClassic.isEnabled;

  Future<List<BluetoothDevice>> getBondedDevices() async {
    final devices = await _blueClassic.bondedDevices;
    return devices ?? const <BluetoothDevice>[];
  }

  Future<void> connect(BluetoothDevice device) async {
    final connection = await _blueClassic.connect(device.address);
    if (connection == null) {
      throw Exception(
        'Gagal terhubung ke ${device.name ?? device.address}. '
        'Pastikan dongle sudah di-pairing di Pengaturan Bluetooth Android '
        'dan tidak sedang dipakai aplikasi lain.',
      );
    }
    _connection = connection;
    _rxBuffer.clear();
    _inputSub = connection.input?.listen(
      _onDataReceived,
      onError: (_) {},
      onDone: () {},
    );
  }

  void _onDataReceived(Uint8List data) {
    final decoded = utf8.decode(data, allowMalformed: true);
    if (_monitoring) {
      _monitorRxBuffer.write(decoded);
      final content = _monitorRxBuffer.toString();
      // Split on CR or LF for monitor lines
      final lines = content.split(RegExp(r'(\r|\n)'));
      for (var i = 0; i < lines.length - 1; i++) {
        final line = lines[i].trim();
        if (line.isNotEmpty) _monitorController.add(line);
      }
      _monitorRxBuffer
        ..clear()
        ..write(lines.last);
      return;
    }

    _rxBuffer.write(decoded);
    final content = _rxBuffer.toString();

    // ELM327 selalu mengakhiri satu balasan penuh dengan karakter prompt '>'.
    // Selama belum ada '>', anggap datanya belum lengkap dan tunggu chunk berikutnya.
    if (content.contains('>')) {
      final parts = content.split('>');
      // Elemen terakhir adalah sisa buffer yang belum ditutup prompt.
      for (var i = 0; i < parts.length - 1; i++) {
        _responseController.add(parts[i]);
      }
      _rxBuffer
        ..clear()
        ..write(parts.last);
    }
  }

  /// Set a custom header for the next requests. Uses the normal command
  /// queue so ordering is preserved.
  Future<String> setHeader(String header) =>
      sendCommand('ATSH$header', timeout: const Duration(seconds: 3));

  /// Protokol OBD yang dipilih ELM327 (hasil ATDPN), mis. 6 = CAN 11-bit
  /// 500k, 7 = CAN 29-bit 500k. null kalau belum diketahui. Diisi oleh
  /// [detectProtocol].
  int? protocol;

  bool get isCan29Bit => protocol == 7 || protocol == 9;

  /// Tanya ELM327 protokol yang sedang aktif. Harus dipanggil setelah ada
  /// komunikasi OBD yang sukses (ATSP0 baru memilih protokol saat request
  /// pertama), mis. sesudah [discoverSupportedPids].
  Future<int?> detectProtocol() async {
    try {
      final resp = await sendCommand('ATDPN');
      final m = RegExp(r'A?([0-9A-C])').firstMatch(resp.trim().toUpperCase());
      protocol = m == null ? null : int.parse(m.group(1)!, radix: 16);
    } catch (_) {
      protocol = null;
    }
    return protocol;
  }

  /// Arahkan request berikutnya ke ECU tertentu (physical addressing).
  /// [header] 3 digit untuk CAN 11-bit (mis. '7E0') atau 8 digit untuk CAN
  /// 29-bit (mis. '18DA10F1'). Versi 8 digit dikirim sebagai ATCP + ATSH
  /// 6 digit supaya jalan juga di klon ELM327 lama.
  Future<void> setEcuHeader(String header) async {
    final h = header.toUpperCase();
    if (h.length == 8) {
      await sendCommand('ATCP${h.substring(0, 2)}');
      await sendCommand('ATSH${h.substring(2)}');
    } else {
      await sendCommand('ATSH$h');
    }
  }

  /// Kembalikan header ke alamat broadcast OBD standar supaya request
  /// Mode 01 biasa jalan lagi tanpa perlu ATZ (yang lambat).
  Future<void> restoreDefaultHeader() =>
      setEcuHeader(isCan29Bit ? '18DB33F1' : '7DF');

  /// Reset header and re-run a short initialize sequence.
  Future<void> resetHeaderAndInitialize() async {
    try {
      // ATZ will reset headers; run via direct queued command so ordering
      // with other queued commands is preserved.
      await sendCommand('ATZ', timeout: const Duration(seconds: 5));
    } catch (_) {}
    await initializeElm327();
  }

  /// Start ATMA monitor mode. While monitoring, raw lines are emitted on
  /// [monitorStream]. This method waits for any prior command queue to
  /// finish, then sends ATMA directly and blocks the command queue until
  /// [stopAtmaMonitor] is called.
  Future<void> startAtmaMonitor() async {
    final connection = _connection;
    if (connection == null || !connection.isConnected) {
      throw StateError('Tidak ada koneksi Bluetooth aktif.');
    }

    // Wait any queued commands to finish first.
    await _commandQueue;

    _monitoring = true;
    _monitorRxBuffer.clear();

    // Send ATMA directly; it will stream frames until we stop.
    connection.output.add(utf8.encode('ATMA\r'));

    // Block the command queue until monitoring stops to prevent mixing modes.
    final completer = Completer<void>();
    _monitorStopCompleter = completer;
    _commandQueue = completer.future;
  }

  /// Stop ATMA monitor mode. This attempts to reset the adapter and then
  /// re-run initialization. It also unblocks the command queue.
  Future<void> stopAtmaMonitor() async {
    final connection = _connection;
    if (!_monitoring) return;
    _monitoring = false;

    // Send a reset to make adapter leave monitor mode. Do it directly.
    try {
      connection?.output.add(utf8.encode('ATZ\r'));
    } catch (_) {}

    // Unblock the command queue first so initializeElm327 can use sendCommand.
    _monitorStopCompleter?.complete();
    _monitorStopCompleter = null;

    // Small delay to allow adapter to reset, then re-initialize.
    await Future.delayed(const Duration(milliseconds: 200));
    await initializeElm327();
  }

  /// Kirim satu command teks (tanpa '\r', akan ditambahkan otomatis) dan
  /// tunggu satu balasan penuh dari ELM327. Command lain yang dipanggil
  /// sebelum ini selesai akan otomatis diantre, bukan dikirim bersamaan.
  Future<String> sendCommand(
    String command, {
    Duration timeout = const Duration(seconds: 3),
  }) {
    final result =
        _commandQueue.then((_) => _sendCommandImpl(command, timeout));
    // Apapun hasil command ini (sukses/gagal), antrean harus tetap lanjut.
    _commandQueue = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<String> _sendCommandImpl(String command, Duration timeout) async {
    final connection = _connection;
    if (connection == null || !connection.isConnected) {
      throw StateError('Tidak ada koneksi Bluetooth aktif ke dongle OBD2.');
    }

    final completer = Completer<String>();
    late final StreamSubscription<String> sub;
    sub = rawResponses.listen((resp) {
      if (!completer.isCompleted) {
        completer.complete(resp);
      }
    });

    try {
      connection.output.add(utf8.encode('$command\r'));
      return await completer.future.timeout(
        timeout,
        onTimeout: () {
          throw TimeoutException(
            'Timeout menunggu respons untuk perintah "$command".',
          );
        },
      );
    } finally {
      await sub.cancel();
    }
  }

  /// Urutan inisialisasi standar ELM327: reset, matikan echo, matikan
  /// line-feed & spasi tambahan, matikan header CAN, lalu biarkan ELM327
  /// pilih sendiri protokol OBD yang cocok dengan mobil (auto-protocol).
  Future<void> initializeElm327() async {
    const initCommands = ['ATZ', 'ATE0', 'ATL0', 'ATS0', 'ATH0', 'ATSP0'];
    for (final cmd in initCommands) {
      try {
        await sendCommand(cmd, timeout: const Duration(seconds: 5));
      } catch (_) {
        // Satu command init gagal/timeout tidak menghentikan seluruh proses;
        // beberapa klon ELM327 memang lambat/aneh merespons command tertentu.
      }
    }
  }

  /// Query PID 00/20/40/60/80/A0/C0 (Mode 01) untuk mendapatkan bitmask PID
  /// apa saja yang didukung mobil, sesuai konvensi SAE J1979. Setiap query
  /// mengembalikan 4 byte = 32 bit, tiap bit mewakili satu PID berikutnya.
  Future<Set<String>> discoverSupportedPids() async {
    final supported = <String>{};
    const bitmaskQueries = ['00', '20', '40', '60', '80', 'A0', 'C0'];

    for (final query in bitmaskQueries) {
      String response;
      try {
        response =
            await sendCommand('01$query', timeout: const Duration(seconds: 3));
      } catch (_) {
        break;
      }

      final bytes = ObdParser.extractDataBytes(
        response,
        expectedMode: '41',
        expectedPid: query,
      );
      if (bytes == null || bytes.length < 4) break;

      final bitmask =
          (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3];
      final basePid = int.parse(query, radix: 16);

      var hasNextRange = false;
      for (var i = 0; i < 32; i++) {
        if ((bitmask & (0x80000000 >> i)) != 0) {
          final pidNum = basePid + i + 1;
          final pidHex = pidNum.toRadixString(16).padLeft(2, '0').toUpperCase();
          supported.add(pidHex);
          // Bit terakhir (i == 31) menandakan PID grup berikutnya (mis. 0x20,
          // 0x40, dst) juga didukung, artinya masih ada rentang PID lanjutan.
          if (i == 31) hasNextRange = true;
        }
      }
      if (!hasNextRange) break;
    }
    return supported;
  }

  Future<void> disconnect() async {
    await _inputSub?.cancel();
    _inputSub = null;
    final connection = _connection;
    _connection = null;
    if (connection != null) {
      try {
        await connection.finish();
      } catch (_) {
        connection.dispose();
      }
    }
  }

  void dispose() {
    _inputSub?.cancel();
    _connection?.dispose();
    _responseController.close();
  }
}
