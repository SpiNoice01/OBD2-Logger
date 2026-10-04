/// Definisi satu PID (Parameter ID) Mode 01 OBD2 standar (SAE J1979),
/// lengkap dengan rumus dekode dari byte mentah ke nilai fisiknya.
class ObdPidDef {
  final String pid; // Kode PID 2 digit hex, contoh: "0C" untuk RPM.
  final String name;
  final String unit;
  final int expectedBytes; // Jumlah byte data minimum yang dibutuhkan rumus decode.
  final double Function(List<int> bytes) decode;

  const ObdPidDef({
    required this.pid,
    required this.name,
    required this.unit,
    required this.expectedBytes,
    required this.decode,
  });
}

/// Tabel PID Mode 01 standar yang paling umum didukung kendaraan.
///
/// CATATAN PENTING soal "posisi gigi transmisi": PID untuk gear position
/// TIDAK ADA di standar SAE J1979 ini. Kalau mobil kamu memancarkannya,
/// itu lewat PID manufacturer-specific (biasanya Mode 21/22), yang berbeda-beda
/// tiap pabrikan dan tidak terdokumentasi resmi. Gunakan RawTerminalScreen
/// di app ini untuk coba-coba mengirim command mentah (misalnya "22XXXX")
/// kalau kamu sudah tahu/menemukan PID khusus merek mobilmu dari forum/reverse
/// engineering, lalu tambahkan hasil temuanmu ke tabel ini.
final List<ObdPidDef> kStandardPids = [
  ObdPidDef(
    pid: '04',
    name: 'Engine Load',
    unit: '%',
    expectedBytes: 1,
    decode: (b) => b[0] * 100 / 255,
  ),
  ObdPidDef(
    pid: '05',
    name: 'Coolant Temperature',
    unit: '°C',
    expectedBytes: 1,
    decode: (b) => (b[0] - 40).toDouble(),
  ),
  ObdPidDef(
    pid: '0A',
    name: 'Fuel Pressure',
    unit: 'kPa',
    expectedBytes: 1,
    decode: (b) => b[0] * 3.0,
  ),
  ObdPidDef(
    pid: '0B',
    name: 'Intake Manifold Pressure',
    unit: 'kPa',
    expectedBytes: 1,
    decode: (b) => b[0].toDouble(),
  ),
  ObdPidDef(
    pid: '0C',
    name: 'Engine RPM',
    unit: 'rpm',
    expectedBytes: 2,
    decode: (b) => (b[0] * 256 + b[1]) / 4,
  ),
  ObdPidDef(
    pid: '0D',
    name: 'Vehicle Speed',
    unit: 'km/h',
    expectedBytes: 1,
    decode: (b) => b[0].toDouble(),
  ),
  ObdPidDef(
    pid: '0E',
    name: 'Timing Advance',
    unit: '°',
    expectedBytes: 1,
    decode: (b) => b[0] / 2 - 64,
  ),
  ObdPidDef(
    pid: '0F',
    name: 'Intake Air Temperature',
    unit: '°C',
    expectedBytes: 1,
    decode: (b) => (b[0] - 40).toDouble(),
  ),
  ObdPidDef(
    pid: '10',
    name: 'MAF Air Flow Rate',
    unit: 'g/s',
    expectedBytes: 2,
    decode: (b) => (b[0] * 256 + b[1]) / 100,
  ),
  ObdPidDef(
    pid: '11',
    name: 'Throttle Position',
    unit: '%',
    expectedBytes: 1,
    decode: (b) => b[0] * 100 / 255,
  ),
  ObdPidDef(
    pid: '1F',
    name: 'Runtime Since Engine Start',
    unit: 's',
    expectedBytes: 2,
    decode: (b) => (b[0] * 256 + b[1]).toDouble(),
  ),
  ObdPidDef(
    pid: '21',
    name: 'Distance with MIL On',
    unit: 'km',
    expectedBytes: 2,
    decode: (b) => (b[0] * 256 + b[1]).toDouble(),
  ),
  ObdPidDef(
    pid: '2F',
    name: 'Fuel Tank Level',
    unit: '%',
    expectedBytes: 1,
    decode: (b) => b[0] * 100 / 255,
  ),
  ObdPidDef(
    pid: '33',
    name: 'Barometric Pressure',
    unit: 'kPa',
    expectedBytes: 1,
    decode: (b) => b[0].toDouble(),
  ),
  ObdPidDef(
    pid: '42',
    name: 'Control Module Voltage',
    unit: 'V',
    expectedBytes: 2,
    decode: (b) => (b[0] * 256 + b[1]) / 1000,
  ),
  ObdPidDef(
    pid: '43',
    name: 'Absolute Load Value',
    unit: '%',
    expectedBytes: 2,
    decode: (b) => (b[0] * 256 + b[1]) * 100 / 255,
  ),
  ObdPidDef(
    pid: '46',
    name: 'Ambient Air Temperature',
    unit: '°C',
    expectedBytes: 1,
    decode: (b) => (b[0] - 40).toDouble(),
  ),
  ObdPidDef(
    pid: '49',
    name: 'Accelerator Pedal Position D',
    unit: '%',
    expectedBytes: 1,
    decode: (b) => b[0] * 100 / 255,
  ),
  ObdPidDef(
    pid: '4A',
    name: 'Accelerator Pedal Position E',
    unit: '%',
    expectedBytes: 1,
    decode: (b) => b[0] * 100 / 255,
  ),
  ObdPidDef(
    pid: '5A',
    name: 'Relative Accelerator Pedal Position',
    unit: '%',
    expectedBytes: 1,
    decode: (b) => b[0] * 100 / 255,
  ),
  ObdPidDef(
    pid: '5C',
    name: 'Engine Oil Temperature',
    unit: '°C',
    expectedBytes: 1,
    decode: (b) => (b[0] - 40).toDouble(),
  ),
  ObdPidDef(
    pid: '5E',
    name: 'Fuel Rate',
    unit: 'L/h',
    expectedBytes: 2,
    decode: (b) => (b[0] * 256 + b[1]) / 20,
  ),
];

/// Cari definisi PID standar berdasarkan kode 2-digit hex-nya (case-insensitive).
ObdPidDef? findPidDef(String pid) {
  final upper = pid.toUpperCase();
  for (final def in kStandardPids) {
    if (def.pid == upper) return def;
  }
  return null;
}
