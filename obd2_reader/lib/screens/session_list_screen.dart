import 'dart:io';

import 'package:flutter/material.dart';

import '../services/data_exporter.dart';
import 'session_viewer_screen.dart';

class SessionListScreen extends StatefulWidget {
  const SessionListScreen({super.key});

  @override
  State<SessionListScreen> createState() => _SessionListScreenState();
}

class _SessionListScreenState extends State<SessionListScreen> {
  late Future<List<File>> _filesFuture;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    _filesFuture = DataExporter.listSessionFiles();
  }

  Future<void> _delete(File f) async {
    await DataExporter.deleteFile(f);
    if (!mounted) return;
    setState(_reload);
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('File dihapus')));
  }

  Future<void> _share(File f) async {
    try {
      await DataExporter.shareFile(f);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Gagal membagikan file')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Sesi Tersimpan')),
      body: FutureBuilder<List<File>>(
        future: _filesFuture,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final files = snap.data ?? [];
          if (files.isEmpty) {
            return const Center(child: Text('Belum ada sesi tersimpan.'));
          }
          final bottomPad = MediaQuery.of(context).padding.bottom;
          return SafeArea(
            bottom: true,
            child: Padding(
              padding: EdgeInsets.fromLTRB(8.0, 8.0, 8.0, 8.0 + bottomPad),
              child: GridView.builder(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  crossAxisSpacing: 8,
                  mainAxisSpacing: 8,
                  childAspectRatio: 0.8,
                ),
                itemCount: files.length,
                itemBuilder: (context, index) {
                  final f = files[index];
                  final stat = f.statSync();
                  final label = _formatLabel(stat.modified);
                  return GestureDetector(
                    onTap: () {
                      Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => SessionViewerScreen(file: f)));
                    },
                    onLongPress: () => _showFileOptions(context, f),
                    child: Card(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Text('🚗', style: TextStyle(fontSize: 24)),
                          const SizedBox(height: 6),
                          Flexible(
                            child: Text(label,
                                textAlign: TextAlign.center,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12)),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          );
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
    return 'OBD LOG\n$y-$m-$d $hh:$mm';
  }

  void _showFileOptions(BuildContext context, File f) {
    showModalBottomSheet<void>(
      context: context,
      builder: (c) => SafeArea(
        child: Wrap(children: [
          ListTile(
            leading: const Icon(Icons.visibility),
            title: const Text('Lihat'),
            onTap: () {
              Navigator.pop(c);
              Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => SessionViewerScreen(file: f)));
            },
          ),
          ListTile(
            leading: const Icon(Icons.share),
            title: const Text('Bagikan'),
            onTap: () async {
              Navigator.pop(c);
              await _share(f);
            },
          ),
          ListTile(
            leading: const Icon(Icons.delete),
            title: const Text('Hapus'),
            onTap: () async {
              Navigator.pop(c);
              final name = f.path.split('\\').last;
              final ok = await showDialog<bool>(
                context: context,
                builder: (c2) => AlertDialog(
                  title: const Text('Hapus file?'),
                  content: Text('Hapus $name?'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(c2, false),
                        child: const Text('Batal')),
                    TextButton(
                        onPressed: () => Navigator.pop(c2, true),
                        child: const Text('Hapus')),
                  ],
                ),
              );
              if (ok == true) await _delete(f);
            },
          ),
        ]),
      ),
    );
  }
}
