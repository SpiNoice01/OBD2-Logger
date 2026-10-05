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
  String? _gear; // label gear, mis. "3", "3M", "N"
  // Nilai terbaru per PID (kunci seperti '05', '0F'), dipakai gauge bawah.
  final Map<String, double> _pidValues = {};

  // Gauge yang tampil di 3 kotak bawah (id dari _kGauges), bisa diganti
  // dengan tap kotaknya.
  List<String> _gaugeSlots = List.of(_kDefaultGaugeSlots);

  // Titik shift light (default 6500 rpm). Juga dipakai sebagai redline untuk
  // shift LED dan zona merah RPM bar.
  int _redline = 6500;
  bool _manualDebugToggle = false;

  // Shift light: berkedip + beep selama rpm >= _redline.
  final ShiftBeeper _beeper = ShiftBeeper();
  Timer? _shiftTimer;
  bool _shiftFlashOn = false;
  bool _beepEnabled = true;

  // Tema warna dash (Gelap, LCD, Navy), digilir lewat tombol tema.
  int _themeIndex = 0; // index ke _DashPalette.all

  // Lampu shift lingkaran besar di kanan bisa disembunyikan. Beep tetap
  // diatur terpisah lewat tombol volume.
  bool _showShiftCircle = true;

  // AppBar auto-hide: muncul saat layar di-tap, hilang lagi setelah
  // beberapa detik tanpa interaksi.
  static const Duration _appBarHideDelay = Duration(seconds: 4);
  bool _appBarVisible = true;
  Timer? _appBarHideTimer;
  _DashPalette get _p => _DashPalette.all[_themeIndex];

  @override
  void initState() {
    super.initState();
    // Force landscape orientation for this screen.
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    // Fullscreen: sembunyikan status bar & tombol navigasi Android
    // (home/back/recent). Swipe dari tepi layar untuk memunculkannya
    // sementara, lalu otomatis hilang lagi.
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
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
      // 'race_lcd_theme' = setting lama (bool) sebelum ada lebih dari 2 tema.
      final theme = sp.getInt('race_theme') ??
          ((sp.getBool('race_lcd_theme') ?? false) ? 1 : 0);
      _themeIndex = theme.clamp(0, _DashPalette.all.length - 1);
      _showShiftCircle = sp.getBool('race_shift_circle') ?? true;
      final slots = sp.getStringList('race_gauge_slots');
      if (slots != null &&
          slots.length == _kDefaultGaugeSlots.length &&
          slots.every(_kGauges.containsKey)) {
        _gaugeSlots = slots;
      }
    });
  }

  Future<void> _setGaugeSlot(int index, String gaugeId) async {
    setState(() => _gaugeSlots[index] = gaugeId);
    final sp = await SharedPreferences.getInstance();
    await sp.setStringList('race_gauge_slots', _gaugeSlots);
  }

  Future<void> _pickGauge(int index) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final g in _kGauges.values)
              ListTile(
                title: Text(g.label),
                subtitle: Text(g.description),
                trailing:
                    g.id == _gaugeSlots[index] ? const Icon(Icons.check) : null,
                onTap: () => Navigator.of(ctx).pop(g.id),
              ),
          ],
        ),
      ),
    );
    if (picked != null) await _setGaugeSlot(index, picked);
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

  /// Ganti ke tema berikutnya (berputar) dan simpan pilihannya.
  Future<void> _cycleTheme() async {
    final next = (_themeIndex + 1) % _DashPalette.all.length;
    setState(() => _themeIndex = next);
    final sp = await SharedPreferences.getInstance();
    await sp.setInt('race_theme', next);
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
    _simSubs.add(_sim.frames.listen((frame) {
      if (!mounted) return;
      setState(() {
        _pidValues.addAll(frame.pids);
        _rpm = frame.pids['0C']?.toInt() ?? 0;
        _speed = frame.pids['0D']?.toInt();
        _gear = frame.gear?.toString();
        _updateShiftLight();
      });
    }));
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
    _pidValues.clear();
    _updateShiftLight();
  }

  void _pullFromController() {
    setState(() {
      // Sample yang gagal decode (null) tidak menimpa nilai terakhir.
      for (final e in _controller.latestByPid.entries) {
        final v = e.value.decodedValue;
        if (v != null) _pidValues[e.key] = v;
      }
      final rpm = _pidValues['0C'];
      if (rpm != null) _rpm = rpm.toInt();
      final spd = _pidValues['0D'];
      if (spd != null) _speed = spd.toInt();
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
    // Kembalikan status bar & tombol navigasi untuk layar lain.
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
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
        width: 20,
        height: 20,
        margin: const EdgeInsets.symmetric(horizontal: 7),
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          // Sedikit glow saat menyala supaya mirip LED asli.
          boxShadow: on
              ? [BoxShadow(color: color.withAlpha(150), blurRadius: 10)]
              : null,
        ),
      );
    });

    // Skala RPM bar dilebihkan sedikit di atas redline supaya zona merah
    // kelihatan (mis. redline 6500 -> skala 0..7000).
    final maxRpm = ((_redline + 500) / 1000).ceil() * 1000;

    return Column(
      children: [
        SizedBox(
          height: 36,
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
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Angka skala RPM dalam ribuan (1 = 1000 rpm).
                    Text('x1000',
                        style: TextStyle(color: _p.label, fontSize: 10)),
                    Text('RPM', style: TextStyle(color: _p.label)),
                  ],
                ),
              ),
            ],
          ),
        )
      ],
    );
  }

  /// GEAR tampil kalau ada sumber gear (simulator, gear ECU Mode 22, atau
  /// estimasi RPM÷speed yang sudah terkalibrasi). Kalau tidak ada, kotak
  /// GEAR disembunyikan dan speed jadi angka utama yang besar.
  bool get _showGear => _simRunning || _controller.gearAvailable;

  Widget _buildCenterHero() {
    final showGear = _showGear;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // Gear
        if (showGear)
          Container(
            padding: const EdgeInsets.all(8),
            child: Column(
              children: [
                Text('GEAR', style: TextStyle(color: _p.label)),
                const SizedBox(height: 8),
                Text(_gear?.toString() ?? '-',
                    style: TextStyle(
                        color: _p.valueColor,
                        fontSize: 96,
                        fontWeight: FontWeight.w700)),
              ],
            ),
          ),
        if (showGear) const SizedBox(width: 40),
        // Speed
        Column(
          children: [
            Text('km/h', style: TextStyle(color: _p.label)),
            const SizedBox(height: 8),
            Text(_speed?.toString() ?? '--',
                style: TextStyle(
                    color: _p.valueColor,
                    fontSize: showGear ? 48 : 96,
                    fontWeight: showGear ? FontWeight.w600 : FontWeight.w700)),
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
    // Tap kotak gauge untuk memilih data yang ditampilkan.
    Widget smallGauge(int index) {
      final g = _kGauges[_gaugeSlots[index]]!;
      final value = g.compute(_pidValues);
      return Expanded(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _pickGauge(index),
          child: Column(
            children: [
              Text(g.label, style: TextStyle(color: _p.label)),
              const SizedBox(height: 8),
              Text(value?.toStringAsFixed(g.digits) ?? '--',
                  style: TextStyle(
                      color: _p.valueColor,
                      fontSize: 24,
                      fontWeight: FontWeight.w500)),
              const SizedBox(height: 4),
              Text(g.unit, style: TextStyle(color: _p.unit, fontSize: 12)),
            ],
          ),
        ),
      );
    }

    return Row(
      children: [
        for (var i = 0; i < _gaugeSlots.length; i++) smallGauge(i),
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
          icon: const Icon(Icons.palette),
          tooltip: 'Ganti tema (sekarang: ${_p.name})',
          onPressed: _cycleTheme,
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
  static const double _labelHeight = 20; // underline + tick + angka

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

    // Garis bawah (underline) sepanjang bar; bagian zona redline merah.
    final lineY = barHeight + 2;
    final redX = (redline / maxRpm).clamp(0.0, 1.0) * size.width;
    final linePaint = Paint()
      ..strokeWidth = 2
      ..color = palette.rpmUnderlineColor;
    canvas.drawLine(Offset(0, lineY), Offset(redX, lineY), linePaint);
    linePaint.color = palette.red;
    canvas.drawLine(Offset(redX, lineY), Offset(size.width, lineY), linePaint);

    // Tick + label tiap 1000 rpm.
    final tickPaint = Paint()
      ..color = palette.rpmUnderlineColor
      ..strokeWidth = 1;
    for (var k = 0; k <= maxRpm ~/ 1000; k++) {
      final x = k * 1000 / maxRpm * size.width;
      canvas.drawLine(Offset(x, lineY), Offset(x, lineY + 4), tickPaint);
      final tp = TextPainter(
        text: TextSpan(
          text: '$k',
          style: TextStyle(
            color: k * 1000 >= redline ? palette.red : palette.rpmScaleColor,
            fontSize: 10,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final lx = (x - tp.width / 2).clamp(0.0, size.width - tp.width);
      tp.paint(canvas, Offset(lx, lineY + 4));
    }
  }

  @override
  bool shouldRepaint(_RpmBarPainter old) =>
      old.rpm != rpm ||
      old.redline != redline ||
      old.maxRpm != maxRpm ||
      old.palette != palette;
}

/// Set warna Race Dash. Tombol tema di AppBar menggilir [all] berurutan.
class _DashPalette {
  const _DashPalette({
    required this.name,
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
    this.rpmScale,
    this.rpmUnderline,
    this.value,
  });

  final String name;
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
  // Warna angka skala RPM (0, 1, 2, ...). null = sama dengan [label].
  final Color? rpmScale;
  Color get rpmScaleColor => rpmScale ?? label;
  // Warna underline & tick RPM (bagian non-redline). null = [label].
  final Color? rpmUnderline;
  Color get rpmUnderlineColor => rpmUnderline ?? label;
  // Warna angka besar (gear, speed, nilai gauge). null = [primary].
  final Color? value;
  Color get valueColor => value ?? primary;

  /// Urutan tema saat tombol tema ditekan. Index disimpan di preferences,
  /// jadi tema baru sebaiknya ditambahkan di akhir.
  static const List<_DashPalette> all = [dark, lcd, navy, black, s2000];

  // Latar gelap + tulisan cyan.
  static const dark = _DashPalette(
    name: 'Gelap',
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

  // Latar biru muda + tulisan biru tua seperti layar LCD dash Haltech.
  static const lcd = _DashPalette(
    name: 'LCD',
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

  // Latar biru gelap yang agak cerah + angka cream, label abu-abu.
  static const navy = _DashPalette(
    name: 'Navy',
    background: Color(0xFF1C3A63),
    primary: Color(0xFFF3E6C8), // cream
    label: Color(0xFFB8C4D1),
    unit: Color(0xFF94A3B5),
    segmentOff: Color(0x24FFFFFF),
    red: Color(0xFFFF6B6B),
    redOff: Color(0x40FF6B6B),
    ledOff: Color(0xFF2E4C78),
    ledGreen: Colors.greenAccent,
    shiftOff: Color(0xFF263F63),
    shiftBorder: Color(0xFF5B7499),
    shiftText: Color(0x40FFFFFF),
  );

  // Latar hitam pekat + angka cream, label cream redup.
  static const black = _DashPalette(
    name: 'Hitam',
    background: Color(0xFF000000),
    primary: Color(0xFFF3E6C8), // cream
    label: Color(0xFFBDB29A),
    unit: Color(0xFF8F8775),
    segmentOff: Color(0x1FF3E6C8),
    red: Color(0xFFFF5252),
    redOff: Color(0x40FF5252),
    ledOff: Color(0xFF2A2A2A),
    ledGreen: Colors.greenAccent,
    shiftOff: Color(0xFF1A0A0A),
    shiftBorder: Color(0xFF3A3A3A),
    shiftText: Color(0x40F3E6C8),
  );

  // "S2000 theme": latar hitam + angka oranye hangat kemerahan, angka skala
  // RPM putih. Nama yang tampil di app tetap "Hitam Oranye".
  static const s2000 = _DashPalette(
    name: 'Hitam Oranye',
    background: Color(0xFF000000),
    primary: Color(0xFFFF7F32), // oranye hangat kemerahan
    label: Color(0xFFD96E38),
    unit: Color(0xFFA8582E),
    segmentOff: Color(0x1FFF7F32),
    // Merah lebih tajam supaya zona merah beda dari angka oranye.
    red: Color(0xFFFF2424),
    redOff: Color(0x40FF2424),
    ledOff: Color(0xFF2A2A2A),
    ledGreen: Colors.greenAccent,
    shiftOff: Color(0xFF1A0A0A),
    shiftBorder: Color(0xFF3A3A3A),
    shiftText: Color(0x40FF7F32),
    // Angka skala RPM putih (yang di zona redline tetap merah).
    rpmScale: Color(0xFFF5F5F5),
    // Underline & tick RPM cream.
    rpmUnderline: Color(0xFFF3E6C8),
    // Angka gear, speed & 3 gauge bawah merah agak gelap, seperti layar
    // LCD merah di dash S2000. Segmen RPM tetap oranye.
    // Merah gelap redline RPM, digeser sedikit ke oranye & dicerahkan.
    value: Color(0xFF6E2A12),
  );
}

/// Pilihan data untuk kotak gauge bawah Race Dash. [compute] menerima nilai
/// terbaru per PID Mode 01 dan mengembalikan null kalau datanya belum ada.
class _GaugeDef {
  const _GaugeDef({
    required this.id,
    required this.label,
    required this.unit,
    required this.digits,
    required this.description,
    required this.compute,
  });

  final String id;
  final String label;
  final String unit;
  final int digits;
  final String description;
  final double? Function(Map<String, double> pids) compute;
}

double? _boostKpa(Map<String, double> pids) {
  final map = pids['0B'];
  if (map == null) return null;
  // Tanpa PID baro, pakai tekanan udara standar permukaan laut.
  return map - (pids['33'] ?? 101.3);
}

final Map<String, _GaugeDef> _kGauges = {
  for (final g in [
    _GaugeDef(
      id: 'coolant',
      label: 'TEMP',
      unit: '°C',
      digits: 0,
      description: 'Suhu air radiator / coolant (PID 05)',
      compute: (p) => p['05'],
    ),
    _GaugeDef(
      id: 'iat',
      label: 'IAT',
      unit: '°C',
      digits: 0,
      description: 'Suhu udara masuk. Makin panas, tenaga makin turun (PID 0F)',
      compute: (p) => p['0F'],
    ),
    const _GaugeDef(
      id: 'boost',
      label: 'BOOST',
      unit: 'kPa',
      digits: 0,
      description: 'MAP - baro. Negatif = vakum (mesin NA), positif = boost '
          'turbo (PID 0B & 33)',
      compute: _boostKpa,
    ),
    _GaugeDef(
      id: 'load',
      label: 'LOAD',
      unit: '%',
      digits: 0,
      description: 'Beban mesin terhitung ECU (PID 04)',
      compute: (p) => p['04'],
    ),
    _GaugeDef(
      id: 'throttle',
      label: 'THR',
      unit: '%',
      digits: 0,
      description: 'Bukaan katup throttle (PID 11)',
      compute: (p) => p['11'],
    ),
    _GaugeDef(
      id: 'batt',
      label: 'BATT',
      unit: 'V',
      digits: 1,
      description: 'Voltase aki / ECU (PID 42)',
      compute: (p) => p['42'],
    ),
  ])
    g.id: g,
};

const List<String> _kDefaultGaugeSlots = ['coolant', 'iat', 'batt'];
