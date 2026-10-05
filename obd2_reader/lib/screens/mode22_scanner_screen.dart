import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../controllers/obd_controller.dart';
import '../models/gear_pid_config.dart';
import '../services/data_exporter.dart';

/// Alat untuk menemukan lokasi data posisi gear di ECU lewat UDS 0x22.
///
/// Alur:
///  1. Cek header ECU mana yang hidup (menjawab Tester Present).
///  2. Scan rentang DID di header yang hidup, catat DID yang menjawab positif.
///  3. Pantau DID yang ketemu sambil menandai posisi gear sekarang
///     (P, R, N, D1..D5, 1M..5M) sesuai indikator di speedometer.
///  4. App mencari byte yang nilainya konsisten per tanda & beda antar tanda
///     -> kandidat byte gear. Kandidat bisa langsung dipakai di Race Dash.
class Mode22ScannerScreen extends StatefulWidget {
  const Mode22ScannerScreen({super.key});

  @override
  State<Mode22ScannerScreen> createState() => _Mode22ScannerScreenState();
}

class _Found {
  _Found(this.header, this.did, this.data);
  final String header;
  final int did;
  List<int> data;

  String get key => '$header/$did';
  String get didHex => did.toRadixString(16).padLeft(4, '0').toUpperCase();
}

class _Snapshot {
  _Snapshot(this.tag, this.time, this.values);
  final String tag;
  final DateTime time;
  final Map<String, List<int>> values; // key _Found.key
}

class _Candidate {
  _Candidate(this.found, this.byteIndex, this.valueByTag);
  final _Found found;
  final int byteIndex;
  final Map<String, int> valueByTag;
  int get distinct => valueByTag.values.toSet().length;
}

class _Mode22ScannerScreenState extends State<Mode22ScannerScreen> {
  static const List<String> _headers29 = [
    '18DA10F1', // ECU mesin / PCM
    '18DA11F1',
    '18DA1EF1', // transmisi (TCM)
    '18DA0EF1',
    '18DA1DF1',
    '18DA60F1', // meter cluster (dugaan)
  ];
  static const List<String> _headers11 = ['7E0', '7E1', '7E2', '7E3'];

  static const List<String> _tags = [
    'P', 'R', 'N', 'D1', 'D2', 'D3', 'D4', 'D5', //
    '1M', '2M', '3M', '4M', '5M',
  ];

  static const List<(String, int, int)> _presets = [
    ('0000-00FF', 0x0000, 0x00FF),
    ('1000-10FF', 0x1000, 0x10FF),
    ('2200-22FF', 0x2200, 0x22FF),
    ('A000-A0FF', 0xA000, 0xA0FF),
    ('F100-F1FF', 0xF100, 0xF1FF),
  ];

  late final ObdController _controller;
  final _customHeader = TextEditingController();
  final _startCtl = TextEditingController(text: '2200');
  final _endCtl = TextEditingController(text: '22FF');

  late List<String> _headerList;
  final Set<String> _selectedHeaders = {};
  final Map<String, bool> _alive = {};

  bool _busy = false; // header check / scan / watch sedang jalan
  bool _cancel = false;
  bool _inExperiment = false;
  String _status = '';
  double? _progress;

  final List<_Found> _found = [];
  bool _watching = false;
  final List<_Snapshot> _snapshots = [];
  List<_Candidate> _candidates = [];

  @override
  void initState() {
    super.initState();
    _controller = context.read<ObdController>();
    _headerList = [
      ...(_controller.isCan29Bit ? _headers29 : _headers11),
      ...(_controller.isCan29Bit ? _headers11 : _headers29),
    ];
    _selectedHeaders.addAll(_controller.isCan29Bit ? _headers29 : _headers11);
  }

  @override
  void dispose() {
    _cancel = true;
    _watching = false;
    if (_inExperiment) {
      _inExperiment = false;
      unawaited(_controller.endExperiment());
    }
    _customHeader.dispose();
    _startCtl.dispose();
    _endCtl.dispose();
    super.dispose();
  }

  Future<void> _enter() async {
    if (_inExperiment) return;
    await _controller.beginExperiment();
    _inExperiment = true;
  }

  Future<void> _leave() async {
    if (!_inExperiment) return;
    _inExperiment = false;
    await _controller.endExperiment();
  }

  void _setStatus(String s, [double? progress]) {
    if (!mounted) return;
    setState(() {
      _status = s;
      _progress = progress;
    });
  }

  // ---- 1. Cek header ----
  Future<void> _checkHeaders() async {
    setState(() {
      _busy = true;
      _cancel = false;
      _alive.clear();
    });
    await _enter();
    final list = _headerList.where(_selectedHeaders.contains).toList();
    for (var i = 0; i < list.length && !_cancel; i++) {
      final h = list[i];
      _setStatus('Cek header $h...', i / list.length);
      await _controller.experimentSetHeader(h);
      final resp = (await _controller.experimentRaw('3E00')).toUpperCase();
      final compact = resp.replaceAll(RegExp(r'\s'), '');
      // 7E00 = tester present OK, 7F3E.. = ditolak tapi ECU-nya ada.
      final alive = compact.contains('7E00') || compact.contains('7F3E');
      if (mounted) setState(() => _alive[h] = alive);
    }
    await _leave();
    final n = _alive.values.where((v) => v).length;
    _setStatus(_cancel ? 'Dibatalkan.' : 'Selesai: $n header menjawab.', null);
    if (mounted) setState(() => _busy = false);
  }

  // ---- 2. Scan DID ----
  int? _parseHex(String s) => int.tryParse(s.trim(), radix: 16);

  Future<void> _scan() async {
    final start = _parseHex(_startCtl.text);
    final end = _parseHex(_endCtl.text);
    if (start == null || end == null || end < start || end > 0xFFFF) {
      _setStatus('Rentang DID tidak valid.');
      return;
    }
    final headers = _alive.entries.where((e) => e.value).map((e) => e.key);
    final targets = headers.isNotEmpty
        ? headers.toList()
        : _headerList.where(_selectedHeaders.contains).toList();
    if (targets.isEmpty) {
      _setStatus('Pilih minimal satu header.');
      return;
    }

    setState(() {
      _busy = true;
      _cancel = false;
    });
    await _enter();
    final total = (end - start + 1) * targets.length;
    var done = 0;
    for (final h in targets) {
      if (_cancel) break;
      await _controller.experimentSetHeader(h);
      for (var did = start; did <= end && !_cancel; did++) {
        final (res, _) = await _controller.experimentReadDid(did);
        done++;
        if (res.isPositive) {
          final f = _found.firstWhere((x) => x.header == h && x.did == did,
              orElse: () {
            final n = _Found(h, did, res.data!);
            _found.add(n);
            return n;
          });
          f.data = res.data!;
        }
        if (done % 4 == 0 || res.isPositive) {
          _setStatus(
              'Scan $h  DID ${did.toRadixString(16).toUpperCase()}'
              '  (${_found.length} ketemu)',
              done / total);
        }
      }
    }
    await _leave();
    _setStatus(
        '${_cancel ? 'Dibatalkan' : 'Selesai'}: ${_found.length} DID ketemu.');
    if (mounted) setState(() => _busy = false);
  }

  // ---- 3. Pantau & tandai ----
  Future<void> _toggleWatch() async {
    if (_watching) {
      setState(() => _watching = false);
      return;
    }
    if (_found.isEmpty) return;
    setState(() {
      _watching = true;
      _busy = true;
      _cancel = false;
    });
    await _enter();
    final byHeader = <String, List<_Found>>{};
    for (final f in _found) {
      byHeader.putIfAbsent(f.header, () => []).add(f);
    }
    var rounds = 0;
    while (_watching && !_cancel && mounted) {
      for (final entry in byHeader.entries) {
        if (!_watching) break;
        await _controller.experimentSetHeader(entry.key);
        for (final f in entry.value) {
          if (!_watching) break;
          final (res, _) = await _controller.experimentReadDid(f.did);
          if (res.isPositive) f.data = res.data!;
        }
      }
      rounds++;
      _setStatus('Memantau ${_found.length} DID (putaran $rounds)');
    }
    await _leave();
    _setStatus('Pemantauan berhenti.');
    if (mounted) setState(() => _busy = false);
  }

  void _tag(String tag) {
    setState(() {
      _snapshots.add(_Snapshot(tag, DateTime.now(), {
        for (final f in _found) f.key: List.of(f.data),
      }));
      _analyze();
    });
  }

  /// Cari byte yang nilainya tetap dalam satu tanda dan berbeda antar tanda.
  void _analyze() {
    final tagsSeen = _snapshots.map((s) => s.tag).toSet();
    final result = <_Candidate>[];
    if (tagsSeen.length >= 2) {
      for (final f in _found) {
        final maxLen = _snapshots
            .map((s) => s.values[f.key]?.length ?? 0)
            .fold(0, (a, b) => a > b ? a : b);
        for (var b = 0; b < maxLen; b++) {
          final perTag = <String, Set<int>>{};
          for (final s in _snapshots) {
            final d = s.values[f.key];
            if (d == null || b >= d.length) continue;
            perTag.putIfAbsent(s.tag, () => {}).add(d[b]);
          }
          if (perTag.length < tagsSeen.length) continue;
          if (perTag.values.any((v) => v.length != 1)) continue;
          final valueByTag = perTag.map((k, v) => MapEntry(k, v.first));
          if (valueByTag.values.toSet().length < 2) continue;
          result.add(_Candidate(f, b, valueByTag));
        }
      }
    }
    result.sort((a, b) => b.distinct.compareTo(a.distinct));
    _candidates = result.take(30).toList();
  }

  Future<void> _useCandidate(_Candidate c) async {
    final labels = <int, String>{};
    for (final t in _tags) {
      final v = c.valueByTag[t];
      if (v == null || labels.containsKey(v)) continue;
      // D1..D5 tampil sebagai angka saja, 1M..5M tetap dengan M.
      labels[v] = t.startsWith('D') ? t.substring(1) : t;
    }
    await _controller.setGearPidConfig(GearPidConfig(
      header: c.found.header,
      did: c.found.did,
      byteIndex: c.byteIndex,
      labels: labels,
    ));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Dipakai. Race Dash sekarang membaca gear dari ECU.')));
  }

  // ---- Export ----
  Future<void> _export() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/mode22_scan_'
        '${DateTime.now().millisecondsSinceEpoch}.csv');
    String hex(List<int> d) =>
        d.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
    final buf = StringBuffer('type,time,tag,header,did,data_hex\n');
    for (final f in _found) {
      buf.writeln('found,,,${f.header},${f.didHex},${hex(f.data)}');
    }
    for (final s in _snapshots) {
      for (final f in _found) {
        final d = s.values[f.key];
        if (d == null) continue;
        buf.writeln('snapshot,${s.time.toIso8601String()},${s.tag},'
            '${f.header},${f.didHex},${hex(d)}');
      }
    }
    await file.writeAsString(buf.toString());
    await DataExporter.shareFile(file);
  }

  // ---- UI ----
  @override
  Widget build(BuildContext context) {
    final ctrl = context.watch<ObdController>();
    final connected = ctrl.connectedDevice != null;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Mode 22 Scanner (Gear)'),
        actions: [
          IconButton(
            tooltip: 'Export CSV',
            icon: const Icon(Icons.share),
            onPressed: _found.isEmpty ? null : _export,
          ),
        ],
      ),
      body: !connected
          ? const Center(
              child: Padding(
              padding: EdgeInsets.all(24),
              child: Text('Sambungkan ke dongle OBD dulu, mesin/kontak ON.',
                  textAlign: TextAlign.center),
            ))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _buildGearSourceCard(ctrl),
                const SizedBox(height: 12),
                if (_status.isNotEmpty) ...[
                  Text(_status),
                  if (_progress != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: LinearProgressIndicator(value: _progress),
                    ),
                  if (_busy && !_watching)
                    TextButton(
                        onPressed: () => setState(() => _cancel = true),
                        child: const Text('Batalkan')),
                  const SizedBox(height: 12),
                ],
                _buildHeaderCard(ctrl),
                const SizedBox(height: 12),
                _buildScanCard(),
                const SizedBox(height: 12),
                if (_found.isNotEmpty) _buildWatchCard(),
                const SizedBox(height: 12),
                if (_candidates.isNotEmpty) _buildCandidatesCard(),
              ],
            ),
    );
  }

  Widget _section(String title, List<Widget> children) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _buildGearSourceCard(ObdController ctrl) {
    final cfg = ctrl.gearPidConfig;
    final est = ctrl.gearEstimator;
    return _section('Sumber gear sekarang', [
      if (cfg != null) ...[
        Text('ECU Mode 22: ${cfg.header}  DID ${cfg.didHex}  '
            'byte ${cfg.byteIndex}'),
        Text(
            'Peta: ${cfg.labels.entries.map((e) => '${_h2(e.key)}=${e.value}').join(', ')}'),
        TextButton(
            onPressed: () => ctrl.setGearPidConfig(null),
            child: const Text('Hapus')),
      ] else
        const Text('ECU Mode 22: belum ada (cari dengan scanner di bawah).'),
      const Divider(),
      Text('Estimasi RPM÷speed: ${est.isCalibrated ? 'siap' : 'belum siap'} '
          '(${est.detectedGears}/${est.gearCount} gigi terdeteksi, '
          '${est.sampleCount} sampel). Terkalibrasi otomatis saat jalan.'),
      TextButton(
          onPressed: () async {
            await est.reset();
            if (mounted) setState(() {});
          },
          child: const Text('Reset kalibrasi')),
      Text('Gear terbaca: ${ctrl.currentGear ?? '-'}'),
    ]);
  }

  Widget _buildHeaderCard(ObdController ctrl) {
    final proto = ctrl.obdProtocol;
    return _section('1. Header ECU', [
      Text('Protokol: ${proto ?? '?'} '
          '(${ctrl.isCan29Bit ? 'CAN 29-bit' : 'CAN 11-bit / lainnya'})'),
      const SizedBox(height: 4),
      Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final h in _headerList)
            FilterChip(
              label: Text(h +
                  (_alive[h] == true
                      ? ' ✓'
                      : _alive[h] == false
                          ? ' ✗'
                          : '')),
              selected: _selectedHeaders.contains(h),
              onSelected: _busy
                  ? null
                  : (v) => setState(() =>
                      v ? _selectedHeaders.add(h) : _selectedHeaders.remove(h)),
            ),
        ],
      ),
      Row(children: [
        Expanded(
          child: TextField(
            controller: _customHeader,
            decoration: const InputDecoration(labelText: 'Header lain (hex)'),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.add),
          onPressed: () {
            final h = _customHeader.text.trim().toUpperCase();
            if (!RegExp(r'^([0-9A-F]{3}|[0-9A-F]{8})$').hasMatch(h)) return;
            setState(() {
              if (!_headerList.contains(h)) _headerList.add(h);
              _selectedHeaders.add(h);
              _customHeader.clear();
            });
          },
        ),
      ]),
      const SizedBox(height: 8),
      FilledButton(
        onPressed: _busy ? null : _checkHeaders,
        child: const Text('Cek header yang menjawab'),
      ),
    ]);
  }

  Widget _buildScanCard() {
    final start = _parseHex(_startCtl.text);
    final end = _parseHex(_endCtl.text);
    final aliveCount = _alive.values.where((v) => v).length;
    final headerCount = aliveCount > 0 ? aliveCount : _selectedHeaders.length;
    final count =
        (start != null && end != null && end >= start) ? end - start + 1 : 0;
    final estSec = (count * headerCount * 0.12).round();
    return _section('2. Scan DID', [
      Wrap(spacing: 6, children: [
        for (final p in _presets)
          ActionChip(
            label: Text(p.$1),
            onPressed: _busy
                ? null
                : () => setState(() {
                      _startCtl.text = _h4(p.$2);
                      _endCtl.text = _h4(p.$3);
                    }),
          ),
      ]),
      Row(children: [
        Expanded(
          child: TextField(
            controller: _startCtl,
            decoration: const InputDecoration(labelText: 'DID awal (hex)'),
            onChanged: (_) => setState(() {}),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: TextField(
            controller: _endCtl,
            decoration: const InputDecoration(labelText: 'DID akhir (hex)'),
            onChanged: (_) => setState(() {}),
          ),
        ),
      ]),
      const SizedBox(height: 4),
      Text('$count DID × $headerCount header ≈ ${estSec ~/ 60}m ${estSec % 60}s'
          '${aliveCount > 0 ? ' (hanya header yang menjawab)' : ''}'),
      const SizedBox(height: 8),
      FilledButton(
        onPressed: _busy ? null : _scan,
        child: const Text('Mulai scan'),
      ),
      if (_found.isNotEmpty) ...[
        const SizedBox(height: 8),
        Text('Ditemukan (${_found.length}):'),
        for (final f in _found.take(50))
          Text('${f.header}  ${f.didHex}:  ${_hex(f.data)}',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
        if (_found.length > 50) Text('…dan ${_found.length - 50} lagi'),
      ],
    ]);
  }

  Widget _buildWatchCard() {
    final counts = <String, int>{};
    for (final s in _snapshots) {
      counts[s.tag] = (counts[s.tag] ?? 0) + 1;
    }
    return _section('3. Pantau & tandai posisi gear', [
      const Text(
          'Nyalakan pantau, lalu setiap kali indikator gear di speedometer '
          'berubah, tekan tombol yang sesuai (2-3x per posisi). Lakukan oleh '
          'penumpang, jangan sambil menyetir.'),
      const SizedBox(height: 8),
      FilledButton.icon(
        onPressed: (_busy && !_watching) ? null : _toggleWatch,
        icon: Icon(_watching ? Icons.stop : Icons.play_arrow),
        label: Text(_watching ? 'Stop pantau' : 'Mulai pantau'),
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final t in _tags)
            OutlinedButton(
              onPressed: _watching ? () => _tag(t) : null,
              child: Text(counts[t] == null ? t : '$t (${counts[t]})'),
            ),
        ],
      ),
      if (_snapshots.isNotEmpty)
        TextButton(
          onPressed: () => setState(() {
            _snapshots.clear();
            _candidates = [];
          }),
          child: const Text('Hapus semua tanda'),
        ),
    ]);
  }

  Widget _buildCandidatesCard() {
    return _section('4. Kandidat byte gear', [
      const Text('Byte yang nilainya tetap di tiap tanda dan berbeda antar '
          'tanda. Pilih yang petanya paling masuk akal.'),
      for (final c in _candidates)
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(
              '${c.found.header}  ${c.found.didHex}  byte ${c.byteIndex}',
              style: const TextStyle(fontFamily: 'monospace')),
          subtitle: Text(_tags
              .where(c.valueByTag.containsKey)
              .map((t) => '$t=${_h2(c.valueByTag[t]!)}')
              .join('  ')),
          trailing: TextButton(
              onPressed: () => _useCandidate(c), child: const Text('Pakai')),
        ),
    ]);
  }

  static String _h2(int v) => v.toRadixString(16).padLeft(2, '0').toUpperCase();
  static String _h4(int v) => v.toRadixString(16).padLeft(4, '0').toUpperCase();
  static String _hex(List<int> d) => d.map(_h2).join(' ');
}
