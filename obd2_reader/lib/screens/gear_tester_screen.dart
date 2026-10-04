import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/obd_controller.dart';

class GearTesterScreen extends StatefulWidget {
  const GearTesterScreen({super.key});

  @override
  State<GearTesterScreen> createState() => _GearTesterScreenState();
}

class _GearTesterScreenState extends State<GearTesterScreen> {
  final List<Map<String, String>> _candidates = [
    {
      'name': 'Candidate 1',
      'header': '18DA0EF1',
      'cmd': '222612',
    },
    {
      'name': 'Candidate 2',
      'header': '18DA1DF1',
      'cmd': '222221',
    },
    {
      'name': 'Candidate 3',
      'header': '18DA1EF1',
      'cmd': '223086',
    },
  ];

  final Map<int, String> _results = {};
  final Map<int, String> _decoded = {};
  final Map<int, bool> _running = {};
  final Map<int, Function()> _pollCancel = {};

  String _decodeCandidate3(String raw) {
    // Try parse hex bytes and decode according to mapping
    try {
      final cleaned = raw.replaceAll(RegExp(r"[^0-9A-Fa-f]"), '');
      if (cleaned.length < 2) return '';
      final byte = int.parse(cleaned.substring(0, 2), radix: 16);
      if (byte == 0) return 'P';
      if (byte >= 1 && byte <= 9) return 'D$byte';
      if (byte == 14) return 'N';
      if (byte == 15) return 'R';
      return 'Unknown($byte)';
    } catch (_) {
      return '';
    }
  }

  Future<void> _testOne(int idx) async {
    final controller = context.read<ObdController>();
    setState(() => _running[idx] = true);
    final cand = _candidates[idx];
    try {
      final resp = await controller.testGearCandidate(
        header: cand['header']!,
        mode22Command: cand['cmd']!,
        timeout: const Duration(seconds: 3),
      );
      setState(() => _results[idx] = resp);
      if (idx == 2) {
        setState(() => _decoded[idx] = _decodeCandidate3(resp));
      }
    } catch (e) {
      setState(() => _results[idx] = 'ERROR: $e');
    } finally {
      setState(() => _running[idx] = false);
    }
  }

  Future<void> _startPolling(int idx) async {
    final controller = context.read<ObdController>();
    setState(() => _running[idx] = true);
    final cand = _candidates[idx];
    final cancel = await controller.startPeriodicGearPolling(
      header: cand['header']!,
      mode22Command: cand['cmd']!,
      interval: const Duration(seconds: 1),
      onData: (raw) {
        setState(() => _results[idx] = raw);
        if (idx == 2) setState(() => _decoded[idx] = _decodeCandidate3(raw));
      },
    );
    _pollCancel[idx] = cancel;
  }

  void _stopPolling(int idx) {
    final cancel = _pollCancel[idx];
    if (cancel != null) cancel();
    _pollCancel.remove(idx);
    setState(() => _running[idx] = false);
  }

  @override
  void dispose() {
    for (final c in _pollCancel.values) {
      c();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Honda Gear Candidate Tester')),
      body: ListView.separated(
        padding: const EdgeInsets.all(12),
        itemCount: _candidates.length,
        separatorBuilder: (_, __) => const SizedBox(height: 12),
        itemBuilder: (context, idx) {
          final cand = _candidates[idx];
          final raw = _results[idx];
          final dec = _decoded[idx];
          final running = _running[idx] ?? false;
          return Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(cand['name']!, style: const TextStyle(fontSize: 16)),
                  const SizedBox(height: 6),
                  Text('Header: ${cand['header']}  Command: ${cand['cmd']}'),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      FilledButton(
                        onPressed: running ? null : () => _testOne(idx),
                        child: const Text('Test'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: running
                            ? () => _stopPolling(idx)
                            : () => _startPolling(idx),
                        child: Text(running ? 'Stop Poll' : 'Start Poll'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (raw != null)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Raw response:',
                            style: TextStyle(fontWeight: FontWeight.bold)),
                        Text(raw,
                            style: const TextStyle(fontFamily: 'monospace')),
                        if (dec != null && dec.isNotEmpty)
                          Text('Decoded: $dec',
                              style:
                                  const TextStyle(fontWeight: FontWeight.bold)),
                      ],
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
