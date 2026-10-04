/// Satu titik data hasil polling satu PID pada satu waktu tertentu.
/// Ini unit data yang disimpan di log dan diexport ke JSON/CSV.
class ObdSample {
  final DateTime timestamp;
  final String pid;
  final String name;
  final String rawHex;
  final double? decodedValue;
  final String unit;

  ObdSample({
    required this.timestamp,
    required this.pid,
    required this.name,
    required this.rawHex,
    required this.decodedValue,
    required this.unit,
  });

  Map<String, dynamic> toJson() => {
        'timestamp': timestamp.toIso8601String(),
        'pid': pid,
        'name': name,
        'raw_hex': rawHex,
        'decoded_value': decodedValue,
        'unit': unit,
      };

  String toCsvRow() {
    String esc(String s) => '"${s.replaceAll('"', '""')}"';
    return [
      timestamp.toIso8601String(),
      pid,
      esc(name),
      esc(rawHex),
      decodedValue?.toString() ?? '',
      unit,
    ].join(',');
  }
}
