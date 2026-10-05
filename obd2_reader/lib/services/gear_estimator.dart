import 'dart:math' as math;

import 'package:shared_preferences/shared_preferences.dart';

/// Menebak gear dari rasio RPM ÷ kecepatan (rpm per km/h). Tiap gigi punya
/// rasio tetap, jadi sambil mobil dipakai jalan, rasio-rasio itu dikumpulkan
/// di histogram; puncak-puncak histogram = rasio tiap gigi. Kalibrasinya
/// otomatis dan tersimpan, tidak perlu input rasio gearbox.
///
/// Batasan: hanya akurat saat torque converter matic sudah lock-up (jalan
/// stabil). Tidak bisa tahu P/R/N atau mode M.
class GearEstimator {
  GearEstimator({this.gearCount = 5});

  /// Jumlah gigi maju transmisi. Gear baru ditampilkan kalau puncak untuk
  /// semua gigi sudah ketemu, supaya penomorannya tidak salah geser.
  final int gearCount;

  static const _prefsKey = 'gear_ratio_histogram';
  static const double _minRatio = 15; // gigi tertinggi, kecepatan tinggi
  static const double _maxRatio = 250; // gigi 1, kecepatan rendah
  static const int _bins = 200;
  static final double _logMin = math.log(_minRatio);
  static final double _binWidth = (math.log(_maxRatio) - _logMin) / _bins;

  // Jarak minimal antar puncak (log rasio). Rasio antar gigi matic 5-speed
  // biasanya beda >= ~25%, jadi puncak yang lebih dekat dianggap gigi sama.
  static const double _minPeakGap = 0.18;
  // Toleransi rasio terhadap puncak saat menebak (~±8%).
  static const double _matchTolerance = 0.08;
  static const int _minSamples = 300;

  List<int> _hist = List.filled(_bins, 0);
  int _total = 0;
  int _unsaved = 0;

  /// Log rasio puncak tiap gigi, urut gigi 1..n. Kosong kalau belum lengkap.
  List<double> _gearLogRatios = const [];

  bool get isCalibrated => _gearLogRatios.length == gearCount;

  /// Jumlah gigi yang puncaknya sudah terdeteksi (untuk info progres).
  int detectedGears = 0;
  int get sampleCount => _total;

  Future<void> load() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getStringList(_prefsKey);
    if (raw != null && raw.length == _bins) {
      _hist = raw.map((s) => int.tryParse(s) ?? 0).toList();
      _total = _hist.fold(0, (a, b) => a + b);
      _recompute();
    }
  }

  Future<void> _save() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setStringList(_prefsKey, _hist.map((c) => '$c').toList());
    _unsaved = 0;
  }

  Future<void> reset() async {
    _hist = List.filled(_bins, 0);
    _total = 0;
    _gearLogRatios = const [];
    detectedGears = 0;
    final sp = await SharedPreferences.getInstance();
    await sp.remove(_prefsKey);
  }

  /// Masukkan satu pasangan rpm & speed terbaru.
  void addSample(double rpm, double speedKmh) {
    // Di bawah ~10 km/h kopling/torque converter masih slip besar.
    if (speedKmh < 10 || rpm < 900) return;
    final bin = _binOf(rpm / speedKmh);
    if (bin == null) return;
    _hist[bin]++;
    _total++;
    if (_total > 50000) {
      // Batasi supaya data lama pelan-pelan tergeser data baru.
      _hist = _hist.map((c) => c ~/ 2).toList();
      _total = _hist.fold(0, (a, b) => a + b);
    }
    if (++_unsaved >= 100) {
      _recompute();
      _save();
    }
  }

  /// Tebakan gear (1..gearCount) untuk rpm & speed sekarang, atau null.
  int? estimate(double? rpm, double? speedKmh) {
    if (!isCalibrated || rpm == null || speedKmh == null) return null;
    if (speedKmh < 10) return null;
    final logR = math.log(rpm / speedKmh);
    var best = -1;
    var bestDist = double.infinity;
    for (var i = 0; i < _gearLogRatios.length; i++) {
      final d = (logR - _gearLogRatios[i]).abs();
      if (d < bestDist) {
        bestDist = d;
        best = i;
      }
    }
    return bestDist <= _matchTolerance ? best + 1 : null;
  }

  int? _binOf(double ratio) {
    if (ratio < _minRatio || ratio >= _maxRatio) return null;
    return ((math.log(ratio) - _logMin) / _binWidth).floor();
  }

  void _recompute() {
    if (_total < _minSamples) {
      _gearLogRatios = const [];
      detectedGears = 0;
      return;
    }
    // Haluskan histogram (jendela ±2 bin) supaya noise tidak jadi puncak.
    final smooth = List<double>.generate(_bins, (i) {
      var s = 0.0;
      for (var j = i - 2; j <= i + 2; j++) {
        if (j >= 0 && j < _bins) s += _hist[j];
      }
      return s;
    });
    final minCount = math.max(15.0, _total * 0.02);
    final peaks = <int>[];
    for (var i = 1; i < _bins - 1; i++) {
      if (smooth[i] >= minCount &&
          smooth[i] >= smooth[i - 1] &&
          smooth[i] > smooth[i + 1]) {
        peaks.add(i);
      }
    }
    // Ambil puncak terbesar dulu, buang yang terlalu dekat puncak terpilih.
    peaks.sort((a, b) => smooth[b].compareTo(smooth[a]));
    final chosen = <double>[];
    for (final p in peaks) {
      final logR = _logMin + (p + 0.5) * _binWidth;
      if (chosen.every((c) => (c - logR).abs() >= _minPeakGap)) {
        chosen.add(logR);
      }
      if (chosen.length == gearCount) break;
    }
    detectedGears = chosen.length;
    // Rasio terbesar = gigi 1.
    chosen.sort((a, b) => b.compareTo(a));
    _gearLogRatios = chosen.length == gearCount ? chosen : const [];
  }
}
