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
