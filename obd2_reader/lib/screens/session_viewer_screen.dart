import 'dart:io';

import 'package:flutter/material.dart';

import '../services/data_exporter.dart';

class SessionViewerScreen extends StatefulWidget {
  final File file;
  const SessionViewerScreen({required this.file, super.key});

  @override
  State<SessionViewerScreen> createState() => _SessionViewerScreenState();
}

class _SessionViewerScreenState extends State<SessionViewerScreen> {
  late Future<String> _contentFuture;

  @override
  void initState() {
    super.initState();
    _contentFuture = DataExporter.readFile(widget.file);
  }

  @override
  Widget build(BuildContext context) {
    final stat = widget.file.statSync();
    final label = _formatLabel(stat.modified);
    return Scaffold(
      appBar: AppBar(
        title: Text(label),
        actions: [
          IconButton(
            icon: const Icon(Icons.share),
            onPressed: () => DataExporter.shareFile(widget.file),
            tooltip: 'Bagikan',
          ),
        ],
      ),
      body: FutureBuilder<String>(
        future: _contentFuture,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final text = snap.data ?? '';
          return SelectableText(text);
        },
      ),
    );
  }

  String _formatLabel(DateTime dt) {
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    return 'OBD LOG $y-$m-$d $hh:$mm';
  }
}
