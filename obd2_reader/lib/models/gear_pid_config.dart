import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Lokasi data posisi gear di ECU (hasil Mode 22 Scanner): header ECU,
/// DID yang dibaca lewat service 0x22, posisi byte di data balasan, dan
/// pemetaan nilai byte -> label gear (mis. 0x03 -> "3", 0x13 -> "3M").
class GearPidConfig {
  const GearPidConfig({
    required this.header,
    required this.did,
    required this.byteIndex,
    required this.labels,
  });

  final String header;
  final int did;
  final int byteIndex;
  final Map<int, String> labels;

  static const _prefsKey = 'gear_pid_config';

  String get didHex => did.toRadixString(16).padLeft(4, '0').toUpperCase();

  /// Label untuk data balasan, atau null kalau nilainya belum dipetakan.
  String? labelFor(List<int> data) {
    if (byteIndex >= data.length) return null;
    return labels[data[byteIndex]];
  }

  Map<String, dynamic> toJson() => {
        'header': header,
        'did': did,
        'byteIndex': byteIndex,
        'labels': labels.map((k, v) => MapEntry(k.toString(), v)),
      };

  static GearPidConfig? fromJson(Map<String, dynamic> j) {
    try {
      return GearPidConfig(
        header: j['header'] as String,
        did: j['did'] as int,
        byteIndex: j['byteIndex'] as int,
        labels: (j['labels'] as Map<String, dynamic>)
            .map((k, v) => MapEntry(int.parse(k), v as String)),
      );
    } catch (_) {
      return null;
    }
  }

  static Future<GearPidConfig?> load() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_prefsKey);
    if (raw == null) return null;
    try {
      return fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(GearPidConfig? config) async {
    final sp = await SharedPreferences.getInstance();
    if (config == null) {
      await sp.remove(_prefsKey);
    } else {
      await sp.setString(_prefsKey, jsonEncode(config.toJson()));
    }
  }
}
