import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter/services.dart';

import '../controllers/obd_controller.dart';
import '../services/data_exporter.dart';
import 'raw_terminal_screen.dart';
import 'session_list_screen.dart';
import 'gear_tester_screen.dart';
import 'mode22_scanner_screen.dart';
import 'can_monitor_screen.dart';

/// Layar utama: menampilkan nilai terbaru tiap PID yang berhasil didekode,
/// plus akses ke terminal mentah dan export data.
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  bool _hasSessions = false;
  bool _shiftActive = false;
  static const double _shiftThreshold = 6600.0;
  @override
  void initState() {
    super.initState();
    _refreshSessionFlag();
  }

  Future<void> _refreshSessionFlag() async {
    try {
      final files = await DataExporter.listSessionFiles();
      if (mounted) setState(() => _hasSessions = files.isNotEmpty);
    } catch (_) {
      if (mounted) setState(() => _hasSessions = false);
    }
  }

  String _stateLabel(ObdConnectionState state) {
    switch (state) {
      case ObdConnectionState.disconnected:
        return 'Terputus';
      case ObdConnectionState.connecting:
        return 'Menghubungkan...';
      case ObdConnectionState.initializing:
        return 'Inisialisasi ELM327...';
      case ObdConnectionState.discoveringPids:
        return 'Mendeteksi PID yang didukung...';
      case ObdConnectionState.ready:
        return 'Siap';
      case ObdConnectionState.polling:
        return 'Membaca data...';
      case ObdConnectionState.error:
        return 'Error';
    }
  }

  Future<void> _handleExport(BuildContext context, String type) async {
    final controller = context.read<ObdController>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      if (type == 'json') {
        await controller.exportAndShareJson();
      } else {
        await controller.exportAndShareCsv();
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Gagal export: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ObdController>(
      builder: (context, controller, _) {
        final isPolling = controller.state == ObdConnectionState.polling;
        final samples = controller.latestByPid.values.toList()
          ..sort((a, b) => a.pid.compareTo(b.pid));

        return Scaffold(
          appBar: AppBar(
            title: Text(controller.connectedDevice?.name ?? 'OBD2 Reader'),
            actions: [
              IconButton(
                icon: const Icon(Icons.folder_open),
                tooltip: 'Sesi tersimpan',
                onPressed: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(
                        builder: (_) => const SessionListScreen()),
                  );
                  _refreshSessionFlag();
                },
              ),
              IconButton(
                icon: Icon(isPolling ? Icons.pause : Icons.play_arrow),
                tooltip: isPolling ? 'Jeda polling' : 'Lanjutkan polling',
                onPressed: () {
                  if (isPolling) {
                    controller.stopPolling();
                  } else {
                    controller.resumePolling();
                  }
                },
              ),
              PopupMenuButton<String>(
                onSelected: (value) async {
                  final messenger = ScaffoldMessenger.of(context);
                  switch (value) {
                    case 'raw':
                      await Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const RawTerminalScreen()),
                      );
                      break;
                    case 'export_json':
                      _handleExport(context, 'json');
                      break;
                    case 'export_csv':
                      _handleExport(context, 'csv');
                      break;
                    case 'share_session':
                      final ok = await controller.shareSessionFile();
                      if (!ok) {
                        messenger.showSnackBar(const SnackBar(
                            content: Text(
                                'Tidak ada file sesi aktif atau gagal membagikan')));
                      }
                      break;
                    case 'view_sessions':
                      await Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => const SessionListScreen()));
                      _refreshSessionFlag();
                      break;
                    case 'disconnect':
                      controller.disconnect();
                      Navigator.of(context).popUntil((r) => r.isFirst);
                      break;
                  }
                },
                itemBuilder: (context) {
                  final items = <PopupMenuEntry<String>>[
                    const PopupMenuItem(
                      value: 'raw',
                      child: Text('Terminal mentah / PID kustom'),
                    ),
                    const PopupMenuItem(
                        value: 'export_json', child: Text('Export JSON')),
                    const PopupMenuItem(
                        value: 'export_csv', child: Text('Export CSV')),
                    const PopupMenuItem(
                        value: 'share_session',
                        child: Text('Bagikan sesi CSV')),
                  ];
                  if (_hasSessions) {
                    items.add(const PopupMenuItem(
                        value: 'view_sessions',
                        child: Text('Lihat sesi tersimpan')));
                  }
                  items.add(const PopupMenuItem(
                      value: 'disconnect', child: Text('Putuskan koneksi')));
                  return items;
                },
              ),
            ],
          ),
          body: Column(
            children: [
              IconButton(
                tooltip: 'Gear tester',
                icon: const Icon(Icons.build),
                onPressed: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const GearTesterScreen()),
                  );
                },
              ),
              IconButton(
                tooltip: 'Mode 22 Scanner (cari gear)',
                icon: const Icon(Icons.manage_search),
                onPressed: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(
                        builder: (_) => const Mode22ScannerScreen()),
                  );
                },
              ),
              IconButton(
                tooltip: 'CAN Monitor',
                icon: const Icon(Icons.wifi_tethering),
                onPressed: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const CanMonitorScreen()),
                  );
                },
              ),
              // Shift light / RPM warning bar
              Builder(builder: (context) {
                final rpmSample = controller.latestByPid['0C']?.decodedValue;
                final rpm = rpmSample ?? 0.0;
                final tempSample = controller.latestByPid['05']?.decodedValue;
                final tempAvailable = tempSample != null;
                final tempVal = tempSample ?? 0.0;
                final active = rpm >= _shiftThreshold;
                // Defer state changes/beep until after build
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!mounted) return;
                  if (active && !_shiftActive) {
                    setState(() => _shiftActive = true);
                    // Play a short system alert sound as a beep
                    SystemSound.play(SystemSoundType.alert);
                  } else if (!active && _shiftActive) {
                    setState(() => _shiftActive = false);
                  }
                });

                // Build 8 lights, with two center lights representing the final threshold
                const percents = [0.45, 0.6, 0.75, 1.0, 1.0, 0.75, 0.6, 0.45];
                final thresholds =
                    percents.map((p) => p * _shiftThreshold).toList();

                final finalReached = rpm >= _shiftThreshold;
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!mounted) return;
                  if (finalReached && !_shiftActive) {
                    setState(() => _shiftActive = true);
                    SystemSound.play(SystemSoundType.alert);
                  } else if (!finalReached && _shiftActive) {
                    setState(() => _shiftActive = false);
                  }
                });

                return Container(
                  color:
                      _shiftActive ? Colors.red.shade700 : Colors.transparent,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Row(
                    children: [
                      // Left-to-right lights grow towards the center
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: List.generate(8, (i) {
                          final thr = thresholds[i];
                          final isActive = rpm >= thr;
                          final isFinal = (percents[i] == 1.0);
                          final color = isActive
                              ? (isFinal ? Colors.white : Colors.orangeAccent)
                              : Colors.grey.shade300;
                          return Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            child: Container(
                              width: 12,
                              height: 12,
                              decoration: BoxDecoration(
                                color: color,
                                shape: BoxShape.circle,
                                boxShadow: isActive
                                    ? [
                                        BoxShadow(
                                          color: isFinal
                                              ? Colors.red.withAlpha(153)
                                              : Colors.orange.withAlpha(102),
                                          blurRadius: 6,
                                          spreadRadius: 1,
                                        )
                                      ]
                                    : null,
                              ),
                            ),
                          );
                        }),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Row(
                          children: [
                            Text(
                              'RPM: ${rpm.toStringAsFixed(0)}',
                              style: TextStyle(
                                color:
                                    _shiftActive ? Colors.white : Colors.black,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(width: 12),
                            if (tempAvailable)
                              Text(
                                'Water: ${tempVal.toStringAsFixed(0)}°C',
                                style: TextStyle(
                                  color: _shiftActive
                                      ? Colors.white70
                                      : Colors.black54,
                                  fontSize: 13,
                                ),
                              ),
                          ],
                        ),
                      ),
                      if (_shiftActive)
                        const Text('SHIFT!',
                            style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold)),
                    ],
                  ),
                );
              }),
              // Compact status: hide verbose status text when connected
              if (controller.state == ObdConnectionState.ready ||
                  controller.state == ObdConnectionState.polling)
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: Row(
                    children: [
                      Icon(
                        Icons.bolt,
                        size: 16,
                        color: Colors.green.shade700,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '${controller.supportedPids.length} PID · ${controller.log.length} sampel',
                        style:
                            const TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                      const Spacer(),
                    ],
                  ),
                )
              else
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Row(
                    children: [
                      Expanded(
                          child:
                              Text('Status: ${_stateLabel(controller.state)}')),
                      Text(
                        '${controller.supportedPids.length} PID · ${controller.log.length} sampel',
                        style:
                            const TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    ],
                  ),
                ),
              if (controller.state == ObdConnectionState.error)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(
                    controller.errorMessage ?? 'Terjadi kesalahan',
                    style: const TextStyle(color: Colors.red),
                  ),
                ),
              Expanded(
                child: samples.isEmpty
                    ? const Center(child: Text('Menunggu data pertama...'))
                    : GridView.builder(
                        padding: const EdgeInsets.all(8),
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          childAspectRatio: 1.5,
                          crossAxisSpacing: 8,
                          mainAxisSpacing: 8,
                        ),
                        itemCount: samples.length,
                        itemBuilder: (context, index) {
                          final sample = samples[index];
                          return Card(
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    sample.name,
                                    style: const TextStyle(
                                        fontSize: 12, color: Colors.grey),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    sample.decodedValue != null
                                        ? '${sample.decodedValue!.toStringAsFixed(1)} ${sample.unit}'
                                        : '-',
                                    style: const TextStyle(
                                      fontSize: 20,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    'PID ${sample.pid} · raw: ${sample.rawHex}',
                                    style: const TextStyle(
                                        fontSize: 10, color: Colors.grey),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}
