import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../controllers/obd_controller.dart';
import '../services/debug_data_simulator.dart';
import '../services/shift_beeper.dart';

class RaceDashScreen extends StatefulWidget {
  const RaceDashScreen({super.key});

  @override
  State<RaceDashScreen> createState() => _RaceDashScreenState();
}

class _RaceDashScreenState extends State<RaceDashScreen> {
  static const int _ledCount = 12;
  // Shift LED mulai menyala dari persentase redline ini.
  static const double _shiftStartFraction = 0.6;

  final DebugDataSimulator _sim = DebugDataSimulator();
  final List<StreamSubscription<dynamic>> _simSubs = [];
  late final ObdController _controller;
  bool _simRunning = false;

  // null = belum ada data (ditampilkan sebagai "--").
  int _rpm = 0;
  int? _speed;
  int? _gear;
  double? _temp;
  double? _load;
  double? _batt;

  // Titik shift light (default 6500 rpm). Juga dipakai sebagai redline untuk
  // shift LED dan zona merah RPM bar.
  int _redline = 6500;
  bool _manualDebugToggle = false;

  // Shift light: berkedip + beep selama rpm >= _redline.
  final ShiftBeeper _beeper = ShiftBeeper();
  Timer? _shiftTimer;
  bool _shiftFlashOn = false;
  bool _beepEnabled = true;

  // Tema warna dash: gelap (default) atau LCD biru muda ala Haltech.
  bool _lcdTheme = false;

  // Lampu shift lingkaran besar di kanan bisa disembunyikan. Beep tetap
  // diatur terpisah lewat tombol volume.
  bool _showShiftCircle = true;

  // AppBar auto-hide: muncul saat layar di-tap, hilang lagi setelah
  // beberapa detik tanpa interaksi.
  static const Duration _appBarHideDelay = Duration(seconds: 4);
  bool _appBarVisible = true;
  Timer? _appBarHideTimer;
  _DashPalette get _p => _lcdTheme ? _DashPalette.lcd : _DashPalette.dark;

  @override
  void initState() {
    super.initState();
    // Force landscape orientation for this screen.
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    _loadPreferences();
    unawaited(_beeper.init());
    _showAppBar(); // tampil sebentar saat dash dibuka, lalu auto-hide
    // Simpan referensi controller supaya listener bisa dilepas di dispose()
    // tanpa perlu context.
    _controller = context.read<ObdController>();
    _controller.addListener(_onControllerChanged);
    _onControllerChanged();
  }

  Future<void> _loadPreferences() async {
    final sp = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _redline = sp.getInt('race_redline') ?? 6500;
      _beepEnabled = sp.getBool('race_beep') ?? true;
      _lcdTheme = sp.getBool('race_lcd_theme') ?? false;
      _showShiftCircle = sp.getBool('race_shift_circle') ?? true;
    });
  }

  /// Tampilkan AppBar dan (ulang) mulai hitung mundur auto-hide.
  void _showAppBar() {
    _appBarHideTimer?.cancel();
    _appBarHideTimer = Timer(_appBarHideDelay, () {
      if (mounted) setState(() => _appBarVisible = false);
    });
    if (!_appBarVisible) setState(() => _appBarVisible = true);
  }

  void _toggleAppBar() {
    if (_appBarVisible) {
      _appBarHideTimer?.cancel();
      setState(() => _appBarVisible = false);
    } else {
      _showAppBar();
    }
  }

  Future<void> _setShowShiftCircle(bool value) async {
    setState(() => _showShiftCircle = value);
    final sp = await SharedPreferences.getInstance();
    await sp.setBool('race_shift_circle', value);
  }

  Future<void> _setLcdTheme(bool value) async {
    setState(() => _lcdTheme = value);
    final sp = await SharedPreferences.getInstance();
    await sp.setBool('race_lcd_theme', value);
  }

  Future<void> _setBeepEnabled(bool value) async {
    setState(() => _beepEnabled = value);
    final sp = await SharedPreferences.getInstance();
    await sp.setBool('race_beep', value);
  }

  bool get _shiftActive => _shiftTimer != null;

  /// Nyalakan/matikan shift light sesuai rpm terbaru. Selama aktif, lampu
  /// berkedip tiap 125 ms dan beep setiap kali lampu menyala (~4x/detik).
  /// Dipanggil setelah _rpm atau _redline berubah (di dalam/sesudah setState).
  void _updateShiftLight() {
    final over = _rpm >= _redline;
    if (over && _shiftTimer == null) {
      _shiftFlashOn = true;
      _beep();
      _shiftTimer = Timer.periodic(const Duration(milliseconds: 125), (_) {
        if (!mounted) return;
        setState(() => _shiftFlashOn = !_shiftFlashOn);
        if (_shiftFlashOn) _beep();
      });
    } else if (!over && _shiftTimer != null) {
      _shiftTimer!.cancel();
      _shiftTimer = null;
      _shiftFlashOn = false;
    }
  }

  void _beep() {
    if (_beepEnabled) unawaited(_beeper.beep());
  }

  bool get _isLive => _controller.connectedDevice != null;

  /// Pilih sumber data: simulator kalau tidak terkoneksi atau Manual Debug
  /// aktif, selain itu data live dari controller. Dipanggil setiap controller
  /// berubah, jadi dash ikut pindah mode kalau dongle putus/tersambung.
  void _onControllerChanged() {
    if (!mounted) return;
    final wantSim = !_isLive || _manualDebugToggle;
    if (wantSim && !_simRunning) {
      _startSim();
    } else if (!wantSim && _simRunning) {
      _stopSim();
    }
    if (!wantSim) _pullFromController();
  }

  void _startSim() {
    _simRunning = true;
    void listen<T>(Stream<T> stream, void Function(T v) apply) {
      _simSubs.add(stream.listen((v) {
        if (mounted) setState(() => apply(v));
      }));
    }

    listen<int>(_sim.rpmStream, (v) {
      _rpm = v;
      _updateShiftLight();
    });
    listen<int>(_sim.speedStream, (v) => _speed = v);
    listen<int?>(_sim.gearStream, (v) => _gear = v);
    listen<double>(_sim.tempStream, (v) => _temp = v);
    listen<double>(_sim.loadStream, (v) => _load = v);
    listen<double>(_sim.battStream, (v) => _batt = v);
    _sim.start();
  }

  void _stopSim() {
    _simRunning = false;
    _sim.stop();
    for (final s in _simSubs) {
      s.cancel();
    }
    _simSubs.clear();
    // Buang nilai simulasi supaya tidak tercampur dengan data live.
    _rpm = 0;
    _speed = null;
    _gear = null;
    _temp = null;
    _load = null;
    _batt = null;
    _updateShiftLight();
  }

  void _pullFromController() {
    final pids = _controller.latestByPid;
    setState(() {
      final rpm = pids['0C']?.decodedValue;
      if (rpm != null) _rpm = rpm.toInt();
      final spd = pids['0D']?.decodedValue;
      if (spd != null) _speed = spd.toInt();
      _temp = pids['05']?.decodedValue ?? _temp;
      _load = pids['04']?.decodedValue ?? _load;
      _batt = pids['42']?.decodedValue ?? _batt;
      _gear = _controller.currentGear;
      _updateShiftLight();
    });
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    _shiftTimer?.cancel();
    _appBarHideTimer?.cancel();
    unawaited(_beeper.dispose());
    // Restore preferred orientations to allow normal device rotation.
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    for (final s in _simSubs) {
      s.cancel();
    }
    _sim.dispose();
    super.dispose();
  }

  Future<void> _saveRedline(int value) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setInt('race_redline', value);
    if (!mounted) return;
    setState(() {
      _redline = value;
      _updateShiftLight();
    });
  }

  Widget _buildTopBar() {
    // Shift LEDs: tiap LED punya warna tetap (hijau -> kuning -> merah),
    // menyala bertahap dari _shiftStartFraction * redline sampai redline.
    // Di atas redline semua LED merah sebagai sinyal shift.
    final shiftStart = _redline * _shiftStartFraction;
    final overRedline = _rpm >= _redline;
    final leds = List.generate(_ledCount, (i) {
      final threshold =
          shiftStart + i / (_ledCount - 1) * (_redline - shiftStart);
      final on = _rpm >= threshold;
      Color color;
      if (!on) {
        color = _p.ledOff;
      } else if (overRedline || i >= _ledCount * 0.75) {
        color = Colors.redAccent;
      } else if (i >= _ledCount * 0.5) {
        color = Colors.amber;
      } else {
        color = _p.ledGreen;
      }
      return Container(
        width: 14,
        height: 14,
        margin: const EdgeInsets.symmetric(horizontal: 4),
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      );
    });

    // Skala RPM bar dilebihkan sedikit di atas redline supaya zona merah
    // kelihatan (mis. redline 6500 -> skala 0..7000).
    final maxRpm = ((_redline + 500) / 1000).ceil() * 1000;

    return Column(
      children: [
        SizedBox(
          height: 28,
          child:
              Row(mainAxisAlignment: MainAxisAlignment.center, children: leds),
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: SizedBox(
                  height: 88,
                  child: CustomPaint(
                    painter: _RpmBarPainter(
                        rpm: _rpm,
                        redline: _redline,
                        maxRpm: maxRpm,
                        palette: _p),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Text('RPM', style: TextStyle(color: _p.label)),
              ),
            ],
          ),
        )
      ],
    );
  }

  Widget _buildCenterHero() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // Gear
        Container(
          padding: const EdgeInsets.all(8),
          child: Column(
            children: [
              Text('GEAR', style: TextStyle(color: _p.label)),
              const SizedBox(height: 8),
              Text(_gear?.toString() ?? '-',
                  style: TextStyle(
                      color: _p.primary,
                      fontSize: 96,
                      fontWeight: FontWeight.w700)),
            ],
          ),
        ),
        const SizedBox(width: 40),
        // Speed
        Column(
          children: [
            Text('km/h', style: TextStyle(color: _p.label)),
            const SizedBox(height: 8),
            Text(_speed?.toString() ?? '--',
                style: TextStyle(
                    color: _p.primary,
                    fontSize: 48,
                    fontWeight: FontWeight.w600)),
          ],
        )
      ],
    );
  }

  /// Lampu shift besar: merah berkedip selama rpm >= titik shift.
  Widget _buildShiftLight(double size) {
    final on = _shiftActive && _shiftFlashOn;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: on ? Colors.redAccent : _p.shiftOff,
        border: Border.all(
          color: _shiftActive ? Colors.redAccent : _p.shiftBorder,
          width: 4,
        ),
        boxShadow: on
            ? const [
                BoxShadow(
                    color: Color(0xB3FF5252), blurRadius: 32, spreadRadius: 6),
              ]
            : null,
      ),
      alignment: Alignment.center,
      child: Padding(
        padding: EdgeInsets.all(size * 0.15),
        child: FittedBox(
          child: Text('SHIFT',
              style: TextStyle(
                  color: on ? Colors.white : _p.shiftText,
                  fontWeight: FontWeight.w800)),
        ),
      ),
    );
  }

  Widget _buildBottomGauges() {
    Widget smallGauge(String label, String value, String unit) {
      return Expanded(
        child: Column(
          children: [
            Text(label, style: TextStyle(color: _p.label)),
            const SizedBox(height: 8),
            Text(value,
                style: TextStyle(
                    color: _p.primary,
                    fontSize: 24,
                    fontWeight: FontWeight.w500)),
            const SizedBox(height: 4),
            Text(unit, style: TextStyle(color: _p.unit, fontSize: 12)),
          ],
        ),
      );
    }

    String fmt(double? v, int digits) => v?.toStringAsFixed(digits) ?? '--';

    return Row(
      children: [
        smallGauge('TEMP', fmt(_temp, 0), '°C'),
        smallGauge('LOAD', fmt(_load, 0), '%'),
        smallGauge('BATT', fmt(_batt, 1), 'V'),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final appBar = AppBar(
      title: const Text('Race Dash'),
      backgroundColor: Colors.black,
      actions: [
        Consumer<ObdController>(builder: (c, ctrl, _) {
          final live = ctrl.connectedDevice != null;
          final showingLive = live && !_manualDebugToggle;
          return Padding(
            padding: const EdgeInsets.all(8.0),
            child: Row(children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                    color: showingLive ? Colors.green : Colors.orange,
                    borderRadius: BorderRadius.circular(8)),
                child: Text(showingLive ? 'LIVE' : 'DEBUG',
                    style: const TextStyle(color: Colors.black)),
              ),
              const SizedBox(width: 8),
              const Text('Manual Debug',
                  style: TextStyle(color: Colors.white70)),
              Switch(
                value: _manualDebugToggle && live,
                onChanged: live
                    ? (v) {
                        setState(() => _manualDebugToggle = v);
                        _onControllerChanged();
                      }
                    : null,
              )
            ]),
          );
        }),
        IconButton(
          icon: Icon(_showShiftCircle
              ? Icons.radio_button_checked
              : Icons.radio_button_unchecked),
          tooltip: _showShiftCircle
              ? 'Sembunyikan lampu shift besar'
              : 'Tampilkan lampu shift besar',
          onPressed: () => _setShowShiftCircle(!_showShiftCircle),
        ),
        IconButton(
          icon: Icon(_lcdTheme ? Icons.dark_mode : Icons.light_mode),
          tooltip: _lcdTheme ? 'Tema gelap' : 'Tema LCD biru',
          onPressed: () => _setLcdTheme(!_lcdTheme),
        ),
        IconButton(
          icon: Icon(_beepEnabled ? Icons.volume_up : Icons.volume_off),
          tooltip: _beepEnabled ? 'Matikan beep' : 'Nyalakan beep',
          onPressed: () => _setBeepEnabled(!_beepEnabled),
        ),
        IconButton(
          icon: const Icon(Icons.settings),
          onPressed: () async {
            final val = await showDialog<int>(
                context: context,
                builder: (ctx) {
                  var temp = _redline;
                  return AlertDialog(
                    title: const Text('Set Shift Light (RPM)'),
                    content: StatefulBuilder(builder: (ctx, setState) {
                      return Column(mainAxisSize: MainAxisSize.min, children: [
                        Slider(
                            value: temp.toDouble(),
                            min: 3000,
                            max: 9000,
                            divisions: 60,
                            label: temp.toString(),
                            onChanged: (v) => setState(() => temp = v.toInt())),
                        Text('$temp rpm'),
                      ]);
                    }),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.of(ctx).pop(null),
                          child: const Text('Cancel')),
                      TextButton(
                          onPressed: () => Navigator.of(ctx).pop(temp),
                          child: const Text('Save')),
                    ],
                  );
                });
            if (val != null) await _saveRedline(val);
          },
        )
      ],
    );

    return Scaffold(
      backgroundColor: _p.background,
      body: Stack(
        children: [
          // Tap di mana saja pada dash untuk memunculkan/menyembunyikan AppBar.
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _toggleAppBar,
            child: _buildDashBody(),
          ),
          // AppBar melayang di atas dash supaya layout dash tidak bergeser
          // saat AppBar muncul/hilang. Setiap sentuhan di AppBar menunda
          // auto-hide.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: IgnorePointer(
              ignoring: !_appBarVisible,
              child: Listener(
                onPointerDown: (_) => _showAppBar(),
                child: AnimatedSlide(
                  offset: _appBarVisible ? Offset.zero : const Offset(0, -1),
                  duration: const Duration(milliseconds: 200),
                  child: AnimatedOpacity(
                    opacity: _appBarVisible ? 1 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: appBar,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDashBody() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            _buildTopBar(),
            const SizedBox(height: 24),
            // FittedBox supaya angka gear/speed mengecil di layar landscape
            // yang pendek alih-alih overflow.
            Expanded(
              child: LayoutBuilder(builder: (context, constraints) {
                final size = (constraints.maxHeight - 16).clamp(0.0, 180.0);
                // Ruang kosong di kiri seukuran lampu shift supaya
                // gear/speed tetap di tengah layar.
                return Row(
                  children: [
                    if (_showShiftCircle) SizedBox(width: size),
                    Expanded(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: _buildCenterHero(),
                      ),
                    ),
                    if (_showShiftCircle) _buildShiftLight(size),
                  ],
                );
              }),
            ),
            const SizedBox(height: 24),
            _buildBottomGauges(),
          ],
        ),
      ),
    );
  }
}

/// RPM bar bergaya segmen putus-putus (ala dash Haltech): tiap segmen makin
/// tinggi ke kanan, segmen di atas redline berwarna merah, dan ada label
/// angka ribuan (0, 1, 2, ...) di bawahnya.
class _RpmBarPainter extends CustomPainter {
  _RpmBarPainter({
    required this.rpm,
    required this.redline,
    required this.maxRpm,
    required this.palette,
  });

  final int rpm;
  final int redline;
  final int maxRpm;
  final _DashPalette palette;

  static const double _segWidth = 4;
  static const double _gap = 2;
  static const double _labelHeight = 14;

  @override
  void paint(Canvas canvas, Size size) {
    final barHeight = size.height - _labelHeight;
    final count = ((size.width + _gap) / (_segWidth + _gap)).floor();
    if (count < 2) return;
    // Lebar segmen disesuaikan supaya bar pas memenuhi lebar yang tersedia.
    final segW = (size.width - _gap * (count - 1)) / count;
    final paint = Paint();

    for (var i = 0; i < count; i++) {
      final segStartRpm = i / count * maxRpm;
      final lit = rpm > segStartRpm;
      final redZone = segStartRpm >= redline;
      paint.color = lit
          ? (redZone ? palette.red : palette.primary)
          : (redZone ? palette.redOff : palette.segmentOff);

      // Tinggi segmen naik dari 35% ke 100% sepanjang bar.
      final h = barHeight * (0.35 + 0.65 * i / (count - 1));
      final x = i * (segW + _gap);
      canvas.drawRect(Rect.fromLTWH(x, barHeight - h, segW, h), paint);
    }

    // Tick + label tiap 1000 rpm.
    final tickPaint = Paint()
      ..color = palette.label
      ..strokeWidth = 1;
    for (var k = 0; k <= maxRpm ~/ 1000; k++) {
      final x = k * 1000 / maxRpm * size.width;
      canvas.drawLine(
          Offset(x, barHeight + 1), Offset(x, barHeight + 4), tickPaint);
      final tp = TextPainter(
        text: TextSpan(
          text: '$k',
          style: TextStyle(
            color: k * 1000 >= redline ? palette.red : palette.label,
            fontSize: 10,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final lx = (x - tp.width / 2).clamp(0.0, size.width - tp.width);
      tp.paint(canvas, Offset(lx, barHeight + 3));
    }
  }

  @override
  bool shouldRepaint(_RpmBarPainter old) =>
      old.rpm != rpm ||
      old.redline != redline ||
      old.maxRpm != maxRpm ||
      old.palette != palette;
}

/// Set warna Race Dash. [dark] = latar gelap + cyan, [lcd] = latar biru muda
/// + tulisan biru tua seperti layar LCD dash Haltech.
class _DashPalette {
  const _DashPalette({
    required this.background,
    required this.primary,
    required this.label,
    required this.unit,
    required this.segmentOff,
    required this.red,
    required this.redOff,
    required this.ledOff,
    required this.ledGreen,
    required this.shiftOff,
    required this.shiftBorder,
    required this.shiftText,
  });

  final Color background;
  final Color primary; // angka utama & segmen RPM yang menyala
  final Color label; // label (GEAR, TEMP, ...) & angka skala RPM
  final Color unit; // satuan (°C, %, V)
  final Color segmentOff;
  final Color red; // zona merah RPM
  final Color redOff;
  final Color ledOff;
  final Color ledGreen; // shift LED hijau yang menyala
  final Color shiftOff;
  final Color shiftBorder;
  final Color shiftText;

  static const dark = _DashPalette(
    background: Color(0xFF021018),
    primary: Colors.cyanAccent,
    label: Color(0xFF18FFC8),
    unit: Color(0xFF18FFA0),
    segmentOff: Color(0x1AFFFFFF),
    red: Colors.redAccent,
    redOff: Color(0x40FF5252),
    ledOff: Color(0xFF424242),
    ledGreen: Colors.greenAccent,
    shiftOff: Color(0xFF2A0A0A),
    shiftBorder: Color(0xFF424242),
    shiftText: Colors.white24,
  );

  static const lcd = _DashPalette(
    background: Color(0xFFA6E6F2),
    primary: Color(0xFF0B2A9E),
    label: Color(0xFF1A3DB8),
    unit: Color(0xFF3A55C0),
    segmentOff: Color(0x260B2A9E),
    red: Color(0xFFD50000),
    redOff: Color(0x40D50000),
    ledOff: Color(0xFF7FB3C2),
    // Hijau tua supaya kontras di latar biru muda.
    ledGreen: Color(0xFF00873A),
    shiftOff: Color(0xFF8CCFDE),
    shiftBorder: Color(0xFF5E9CAD),
    shiftText: Color(0x660B2A9E),
  );
}
