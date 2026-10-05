import 'package:flutter/material.dart';
import 'package:flutter_blue_classic/flutter_blue_classic.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../controllers/obd_controller.dart';
import '../controllers/theme_controller.dart';
import 'dashboard_screen.dart';
import 'race_dash_screen.dart';
import 'session_list_screen.dart';

/// Layar awal: minta izin Bluetooth runtime, lalu tampilkan daftar
/// perangkat Bluetooth yang SUDAH di-pairing (bonded) di Android.
///
/// Catatan: dongle OBD2 classic (SPP) harus dipasangkan dulu lewat
/// Pengaturan Bluetooth bawaan Android (biasanya minta PIN 1234 atau 0000)
/// sebelum bisa muncul & dipilih di sini.
class DeviceListScreen extends StatefulWidget {
  const DeviceListScreen({super.key});

  @override
  State<DeviceListScreen> createState() => _DeviceListScreenState();
}

class _DeviceListScreenState extends State<DeviceListScreen> {
  List<BluetoothDevice> _devices = [];
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  Future<void> _init() async {
    await _requestPermissions();
    await _refreshDevices();
  }

  Future<void> _requestPermissions() async {
    await [
      Permission.bluetoothConnect,
      Permission.bluetoothScan,
    ].request();
  }

  Future<void> _refreshDevices() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final controller = context.read<ObdController>();
      final devices = await controller.loadBondedDevices();
      if (!mounted) return;
      setState(() => _devices = devices);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Gagal mengambil daftar perangkat: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _connect(BluetoothDevice device) {
    final controller = context.read<ObdController>();
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const DashboardScreen()),
    );
    controller.connectAndInitialize(device);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pilih Dongle OBD2'),
        actions: [
          IconButton(
            onPressed: () {
              Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const RaceDashScreen()));
            },
            icon: const Icon(Icons.speed),
            tooltip: 'Buka Race Dash (simulasi)',
          ),
          // Start/stop recording session manually from homepage.
          Consumer<ObdController>(builder: (context, controller, _) {
            final recording = controller.isSessionRecording;
            return IconButton(
              onPressed: () async {
                final messenger = ScaffoldMessenger.of(context);
                if (!recording) {
                  final ok = await controller.startSessionLogging();
                  if (ok) {
                    messenger.showSnackBar(
                        const SnackBar(content: Text('Mulai merekam sesi')));
                  } else {
                    messenger.showSnackBar(
                        const SnackBar(content: Text('Gagal memulai rekaman')));
                  }
                } else {
                  controller.stopSessionLogging();
                  messenger.showSnackBar(
                      const SnackBar(content: Text('Berhenti merekam sesi')));
                }
              },
              icon: Icon(recording ? Icons.stop : Icons.fiber_manual_record,
                  color: recording ? null : Colors.red),
              tooltip: recording ? 'Stop recording' : 'Start recording',
            );
          }),
          // Theme toggle
          Consumer<ThemeController>(builder: (context, themeCtrl, _) {
            return IconButton(
              onPressed: () => themeCtrl.toggle(),
              icon: Icon(themeCtrl.isDark ? Icons.dark_mode : Icons.light_mode),
              tooltip: themeCtrl.isDark ? 'Switch to light' : 'Switch to dark',
            );
          }),
          IconButton(
            onPressed: _loading ? null : _refreshDevices,
            icon: const Icon(Icons.refresh),
            tooltip: 'Muat ulang daftar perangkat',
          ),
          PopupMenuButton<String>(
            onSelected: (value) async {
              switch (value) {
                case 'view_sessions':
                  await Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => const SessionListScreen()));
                  break;
              }
            },
            itemBuilder: (c) => const [
              PopupMenuItem(
                  value: 'view_sessions', child: Text('Lihat sesi tersimpan'))
            ],
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refreshDevices,
        child: ListView(
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Pastikan dongle OBD2 sudah dipasangkan (paired) lewat '
                'Pengaturan Bluetooth Android terlebih dahulu, baru pilih '
                'perangkatnya di bawah ini.',
              ),
            ),
            if (_loading) const LinearProgressIndicator(),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(_error!, style: const TextStyle(color: Colors.red)),
              ),
            if (!_loading && _devices.isEmpty && _error == null)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('Belum ada perangkat Bluetooth yang dipasangkan.'),
              ),
            for (final device in _devices)
              ListTile(
                leading: const Icon(Icons.bluetooth),
                title: Text(device.name ?? '(Tanpa nama)'),
                subtitle: Text(device.address),
                onTap: () => _connect(device),
              ),
          ],
        ),
      ),
    );
  }
}
