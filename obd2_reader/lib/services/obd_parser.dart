/// Parser respons mentah ELM327 (teks hex ASCII) menjadi list byte data.
///
/// Respons ELM327 untuk satu command bisa berisi beberapa baris (dipisah
/// CR/LF), kadang diselingi pesan status seperti "SEARCHING...". Parser ini
/// menyaring baris status/error dan mencari baris yang polanya cocok dengan
/// mode+PID yang diharapkan, lalu mengubah sisa token hex-nya jadi byte.
class ObdParser {
  static List<int>? extractDataBytes(
    String rawResponse, {
    required String expectedMode,
    String? expectedPid,
  }) {
    final lines = rawResponse
        .split(RegExp(r'[\r\n]+'))
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();

    for (final line in lines) {
      final upper = line.toUpperCase().replaceAll(' ', '');

      if (upper.contains('SEARCHING') ||
          upper.contains('NODATA') ||
          upper.contains('UNABLETOCONNECT') ||
          upper.contains('ERROR') ||
          upper.contains('STOPPED') ||
          upper == '?') {
        continue;
      }

      // Baris harus berupa deretan pasangan hex (jumlah karakter genap).
      if (upper.isEmpty || upper.length % 2 != 0) continue;
      if (!RegExp(r'^[0-9A-F]+$').hasMatch(upper)) continue;

      final tokens = <String>[];
      for (var i = 0; i + 1 < upper.length; i += 2) {
        tokens.add(upper.substring(i, i + 2));
      }
      if (tokens.isEmpty) continue;
      if (tokens[0] != expectedMode.toUpperCase()) continue;

      List<String> dataTokens;
      if (expectedPid != null) {
        if (tokens.length < 2 || tokens[1] != expectedPid.toUpperCase()) {
          continue;
        }
        dataTokens = tokens.sublist(2);
      } else {
        dataTokens = tokens.sublist(1);
      }
      if (dataTokens.isEmpty) continue;

      try {
        return dataTokens.map((t) => int.parse(t, radix: 16)).toList();
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  /// Gabungkan respons ELM327 (single atau multi-frame ISO-TP) jadi satu
  /// deret byte. Format multi-frame dengan ATH0/ATS0 berupa baris panjang
  /// total ("00B") lalu baris berindeks ("0:62...", "1:..."); indeks dan
  /// baris panjang dibuang. Return null kalau tidak ada data hex.
  static List<int>? joinFrames(String rawResponse) {
    final lines = rawResponse
        .split(RegExp(r'[\r\n]+'))
        .map((l) => l.trim().toUpperCase().replaceAll(' ', ''))
        .where((l) => l.isNotEmpty)
        .toList();
    final isMulti = lines.any((l) => RegExp(r'^[0-9A-F]:').hasMatch(l));
    final hex = StringBuffer();
    for (final line in lines) {
      if (isMulti) {
        final m = RegExp(r'^[0-9A-F]:([0-9A-F]+)$').firstMatch(line);
        if (m != null) hex.write(m.group(1));
        // Baris tanpa indeks di respons multi-frame = panjang total, skip.
      } else if (RegExp(r'^[0-9A-F]+$').hasMatch(line) &&
          line.length.isEven) {
        hex.write(line);
      }
    }
    final s = hex.toString();
    if (s.isEmpty) return null;
    return [
      for (var i = 0; i + 1 < s.length; i += 2)
        int.parse(s.substring(i, i + 2), radix: 16),
    ];
  }

  /// Hasil request UDS 0x22 (ReadDataByIdentifier) untuk [did].
  /// - bytes data (sesudah "62 DD DD") kalau positif,
  /// - [Mode22Result.nrc] terisi kalau ECU menolak ("7F 22 xx"),
  /// - keduanya null kalau tidak ada balasan (NO DATA / timeout / sampah).
  static Mode22Result parseMode22(String rawResponse, int did) {
    final bytes = joinFrames(rawResponse);
    if (bytes == null || bytes.isEmpty) return const Mode22Result();
    for (var i = 0; i + 2 < bytes.length; i++) {
      if (bytes[i] == 0x7F && bytes[i + 1] == 0x22) {
        return Mode22Result(nrc: bytes[i + 2]);
      }
    }
    final hi = (did >> 8) & 0xFF, lo = did & 0xFF;
    for (var i = 0; i + 2 < bytes.length; i++) {
      if (bytes[i] == 0x62 && bytes[i + 1] == hi && bytes[i + 2] == lo) {
        return Mode22Result(data: bytes.sublist(i + 3));
      }
    }
    return const Mode22Result();
  }

  /// Deteksi cepat apakah suatu respons mentah menandakan kegagalan
  /// (tidak ada data / tidak konek / error), berguna untuk ditampilkan
  /// apa adanya di layar terminal mentah.
  static bool looksLikeError(String rawResponse) {
    final u = rawResponse.toUpperCase();
    return u.contains('NO DATA') ||
        u.contains('UNABLE TO CONNECT') ||
        u.contains('ERROR') ||
        u.contains('STOPPED');
  }
}

class Mode22Result {
  const Mode22Result({this.data, this.nrc});

  /// Byte data sesudah "62 DID". null kalau tidak positif.
  final List<int>? data;

  /// Negative response code ECU (mis. 0x31 = DID tidak ada). null kalau
  /// bukan respons negatif.
  final int? nrc;

  bool get isPositive => data != null;

  /// ECU menjawab (positif atau negatif): artinya alamat header-nya hidup.
  bool get ecuAnswered => data != null || nrc != null;
}
