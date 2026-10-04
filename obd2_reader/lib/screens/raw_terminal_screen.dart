import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/obd_controller.dart';

class _TerminalEntry {
  final String command;
  final String response;
  _TerminalEntry(this.command, this.response);
}

/// Terminal mentah: kirim command AT atau PID apa saja langsung ke ELM327
/// dan lihat balasan mentahnya. Ini "pintu belakang" untuk eksplorasi PID
/// yang tidak ada di tabel standar -- termasuk PID posisi gigi transmisi
/// yang manufacturer-specific dan tidak distandarkan SAE J1979.
class RawTerminalScreen extends StatefulWidget {
  const RawTerminalScreen({super.key});

  @override
  State<RawTerminalScreen> createState() => _RawTerminalScreenState();
}

class _RawTerminalScreenState extends State<RawTerminalScreen> {
  final _controller = TextEditingController();
  final _history = <_TerminalEntry>[];
  final _scrollController = ScrollController();
  bool _sending = false;

  Future<void> _send() async {
    final command = _controller.text.trim();
    if (command.isEmpty || _sending) return;
    setState(() => _sending = true);

    final obd = context.read<ObdController>();
    try {
      final response = await obd.sendRawCommand(command);
      if (!mounted) return;
      setState(() => _history.add(_TerminalEntry(command, response.trim())));
    } catch (e) {
      if (!mounted) return;
      setState(() => _history.add(_TerminalEntry(command, 'ERROR: $e')));
    } finally {
      setState(() => _sending = false);
      _controller.clear();
      if (mounted) {
        await Future.delayed(const Duration(milliseconds: 50));
        if (_scrollController.hasClients) {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
          );
        }
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Terminal Mentah')),
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text(
              'Kirim perintah AT atau PID mentah langsung ke ELM327. Berguna '
              'untuk mencoba PID khusus pabrikan (biasanya mode 21/22) yang '
              'tidak ada di daftar PID standar, misalnya posisi gigi transmisi.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: _history.length,
              itemBuilder: (context, index) {
                final entry = _history[index];
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '> ${entry.command}',
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        entry.response,
                        style: const TextStyle(fontFamily: 'monospace'),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    textCapitalization: TextCapitalization.characters,
                    decoration: const InputDecoration(
                      hintText: 'contoh: 010C atau ATRV',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _send(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  onPressed: _sending ? null : _send,
                  icon: _sending
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.send),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
