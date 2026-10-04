import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/obd_sample.dart';

/// Menulis log sample OBD2 yang sudah terkumpul ke file JSON/CSV di
/// penyimpanan aplikasi, lalu membukanya lewat share sheet Android supaya
/// mudah dipindahkan ke aplikasi lain (Drive, email, Python di laptop, dst)
/// untuk diolah lebih lanjut.
class DataExporter {
  static Future<File> exportJson(List<ObdSample> samples) async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File(
      '${dir.path}/obd2_log_${DateTime.now().millisecondsSinceEpoch}.json',
    );
    final jsonList = samples.map((s) => s.toJson()).toList();
    await file
        .writeAsString(const JsonEncoder.withIndent('  ').convert(jsonList));
    return file;
  }

  static Future<File> exportCsv(List<ObdSample> samples) async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File(
      '${dir.path}/obd2_log_${DateTime.now().millisecondsSinceEpoch}.csv',
    );
    final buffer = StringBuffer()
      ..writeln('timestamp,pid,name,raw_hex,decoded_value,unit');
    for (final s in samples) {
      buffer.writeln(s.toCsvRow());
    }
    await file.writeAsString(buffer.toString());
    return file;
  }

  /// Create a new session CSV file with header and return the File.
  static Future<File> createSessionCsv() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File(
      '${dir.path}/obd2_session_${DateTime.now().millisecondsSinceEpoch}.csv',
    );
    await file.writeAsString('timestamp,pid,name,raw_hex,decoded_value,unit\n');
    return file;
  }

  /// Append a single sample as a CSV row to an existing session file.
  static Future<void> appendSample(File file, ObdSample sample) async {
    await file.writeAsString('${sample.toCsvRow()}\n',
        mode: FileMode.append, flush: true);
  }

  static Future<void> shareFile(File file) async {
    await Share.shareXFiles([XFile(file.path)]);
  }

  /// List all session CSV files created by the app, sorted by newest first.
  static Future<List<File>> listSessionFiles() async {
    final dir = await getApplicationDocumentsDirectory();
    final folder = Directory(dir.path);
    if (!await folder.exists()) return [];
    final files = await folder
        .list()
        .where((f) =>
            f is File &&
            f.path.contains('obd2_session_') &&
            f.path.endsWith('.csv'))
        .map((f) => f as File)
        .toList();
    files.sort((a, b) => b.path.compareTo(a.path));
    return files;
  }

  static Future<String> readFile(File file) async {
    return file.readAsString();
  }

  static Future<void> deleteFile(File file) async {
    if (await file.exists()) {
      await file.delete();
    }
  }
}
