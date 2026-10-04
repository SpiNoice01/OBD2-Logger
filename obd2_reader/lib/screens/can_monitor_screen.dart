import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/obd_controller.dart';
import '../services/data_exporter.dart';

class CanMonitorScreen extends StatefulWidget {
  const CanMonitorScreen({super.key});

  @override
  State<CanMonitorScreen> createState() => _CanMonitorScreenState();
}

class _CanMonitorScreenState extends State<CanMonitorScreen> {
  bool _running = false;
  int _count = 0;
  StreamSubscription<String>? _sub;
  final List<Map<String, String>> _buffer = [];
  Timer? _flushTimer;

  Future<void> _start() async {
    final controller = context.read<ObdController>();
    try {
      controller.pausePollingForExperiment();
      await controller.startAtmaMonitor();
      _sub = controller.monitorStream.listen((line) {
        setState(() {
          _count++;
          _buffer.add({'ts': DateTime.now().toIso8601String(), 'line': line});
          if (_buffer.length > 5000) _buffer.removeAt(0);
        });
      });
      setState(() => _running = true);
      // Periodically flush to disk to avoid memory growth
      _flushTimer =
          Timer.periodic(const Duration(seconds: 5), (_) => _flushToFile());
    } catch (e) {
      controller.resumePollingAfterExperiment();
      rethrow;
    }
  }

  Future<void> _stop() async {
    final controller = context.read<ObdController>();
    _flushTimer?.cancel();
    await controller.stopAtmaMonitor();
    await _sub?.cancel();
    setState(() => _running = false);
    controller.resumePollingAfterExperiment();
  }

  Future<File> _flushToFile() async {
    final dir = await DataExporter.createSessionCsv();
    final file = dir;
    // append buffer lines as CSV rows timestamp,raw_frame
    final sink = file.openWrite(mode: FileMode.append);
    for (final r in _buffer) {
      sink.writeln('${r['ts']},"${r['line']}"');
    }
    await sink.flush();
    await sink.close();
    _buffer.clear();
    return file;
  }

  Future<void> _exportNow() async {
    final file = await _flushToFile();
    await DataExporter.shareFile(file);
  }

  @override
  void dispose() {
    _flushTimer?.cancel();
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('CAN Monitor (ATMA)')),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
                'Safety: lakukan pengujian mobil dalam kondisi diam, rem aktif.'),
            const SizedBox(height: 8),
            Row(children: [
              FilledButton(
                onPressed: _running ? null : _start,
                child: const Text('Start'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: !_running ? null : _stop,
                child: const Text('Stop'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _buffer.isEmpty ? null : _exportNow,
                child: const Text('Export'),
              ),
            ]),
            const SizedBox(height: 12),
            Text('Frames captured: $_count'),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                itemCount: _buffer.length,
                itemBuilder: (context, idx) {
                  final row = _buffer[idx];
                  return ListTile(
                    dense: true,
                    title: Text(row['line'] ?? ''),
                    subtitle: Text(row['ts'] ?? ''),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
