import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';

/// Pemutar bunyi "beep" pendek untuk shift light. Nada dibuat langsung di
/// kode (WAV sinus) lalu disimpan ke folder temporary, jadi tidak perlu
/// file aset audio.
class ShiftBeeper {
  static const int _sampleRate = 44100;
  static const double _freqHz = 2000;
  static const int _durationMs = 90;

  final AudioPlayer _player = AudioPlayer();
  bool _ready = false;

  Future<void> init() async {
    try {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/shift_beep.wav');
      await file.writeAsBytes(_buildBeepWav());
      // Mix dengan audio lain (musik/navigasi) supaya tidak memotongnya.
      await _player.setAudioContext(
          AudioContextConfig(focus: AudioContextConfigFocus.mixWithOthers)
              .build());
      await _player.setReleaseMode(ReleaseMode.stop);
      await _player.setSource(DeviceFileSource(file.path));
      _ready = true;
    } catch (_) {
      // Audio gagal disiapkan: shift light tetap jalan, hanya tanpa bunyi.
      _ready = false;
    }
  }

  Future<void> beep() async {
    if (!_ready) return;
    try {
      await _player.seek(Duration.zero);
      await _player.resume();
    } catch (_) {}
  }

  Future<void> dispose() => _player.dispose();

  /// WAV PCM 16-bit mono berisi nada sinus dengan fade in/out singkat
  /// supaya tidak ada bunyi "klik" di awal/akhir.
  static Uint8List _buildBeepWav() {
    const numSamples = _sampleRate * _durationMs ~/ 1000;
    const fadeSamples = _sampleRate * 5 ~/ 1000; // 5 ms
    const dataSize = numSamples * 2;
    final bytes = ByteData(44 + dataSize);

    void writeAscii(int offset, String s) {
      for (var i = 0; i < s.length; i++) {
        bytes.setUint8(offset + i, s.codeUnitAt(i));
      }
    }

    writeAscii(0, 'RIFF');
    bytes.setUint32(4, 36 + dataSize, Endian.little);
    writeAscii(8, 'WAVE');
    writeAscii(12, 'fmt ');
    bytes.setUint32(16, 16, Endian.little); // ukuran chunk fmt
    bytes.setUint16(20, 1, Endian.little); // PCM
    bytes.setUint16(22, 1, Endian.little); // mono
    bytes.setUint32(24, _sampleRate, Endian.little);
    bytes.setUint32(28, _sampleRate * 2, Endian.little); // byte rate
    bytes.setUint16(32, 2, Endian.little); // block align
    bytes.setUint16(34, 16, Endian.little); // bits per sample
    writeAscii(36, 'data');
    bytes.setUint32(40, dataSize, Endian.little);

    for (var i = 0; i < numSamples; i++) {
      var amp = 0.8;
      if (i < fadeSamples) amp *= i / fadeSamples;
      if (i > numSamples - fadeSamples) {
        amp *= (numSamples - i) / fadeSamples;
      }
      final v = math.sin(2 * math.pi * _freqHz * i / _sampleRate) * amp;
      bytes.setInt16(44 + i * 2, (v * 32767).round(), Endian.little);
    }
    return bytes.buffer.asUint8List();
  }
}
