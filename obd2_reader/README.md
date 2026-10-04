# OBD2 Reader (Flutter, Bluetooth Classic / ELM327)

App Android sederhana yang konek ke dongle OBD2 Bluetooth Classic (SPP,
kebanyakan dongle ELM327 murah), otomatis mendeteksi PID standar (Mode 01,
SAE J1979) yang didukung mobil, lalu polling terus-menerus dan menampilkan
nilai mentah (hex) + nilai yang sudah didekode (RPM, suhu, dll). Semua data
bisa diexport ke JSON/CSV untuk diolah lebih lanjut di luar app.

## Kenapa strukturnya begini

Karena sandbox tempat kode ini ditulis tidak bisa mengunduh Flutter/Dart SDK
(diblokir kebijakan jaringan), project ini **belum pernah dijalankan
`flutter pub get` / `flutter run` / `flutter analyze`**. Semua file `lib/`
dan `pubspec.yaml` ditulis manual dan sudah direview dua kali (termasuk
verifikasi API package `flutter_blue_classic` langsung dari source code
GitHub-nya, bukan tebakan) untuk meminimalkan kesalahan, tapi kamu tetap
perlu generate folder `android/` (dan `ios/`, kalau nanti diperlukan) lewat
`flutter create` sendiri di komputer yang punya Flutter SDK terpasang,
karena folder platform-native itu isinya ratusan file boilerplate yang
riskan kalau ditulis tangan.

## Langkah setup

1. Pastikan Flutter SDK sudah terpasang (`flutter doctor`).
2. Buat project baru untuk dapat folder `android/`, `ios/`, dll yang valid:
   ```bash
   flutter create --org com.example obd2_reader
   ```
3. Timpa isi `lib/` hasil `flutter create` dengan folder `lib/` dari paket
   ini (folder ini berisi `main.dart`, `controllers/`, `models/`, `services/`,
   `screens/`).
4. Timpa `pubspec.yaml` hasil `flutter create` dengan `pubspec.yaml` dari
   paket ini (atau cukup salin bagian `dependencies:`-nya kalau kamu mau
   pertahankan nama package/org yang di-generate `flutter create`).
5. Buka `android/app/src/main/AndroidManifest.xml`, tempel isi
   `android_manifest_permissions.xml` (dari paket ini) tepat sebelum tag
   `<application>`.
6. Cek `android/app/build.gradle` (atau `android/app/build.gradle.kts`):
   pastikan `minSdkVersion` / `minSdk` minimal **21** (default template
   Flutter sekarang biasanya sudah di atas itu, tapi tetap cek).
7. Jalankan:
   ```bash
   flutter pub get
   ```
8. Pasangkan (pairing) dongle OBD2 dulu lewat **Pengaturan Bluetooth Android
   bawaan** (bukan dari dalam app ini) — biasanya minta PIN `1234` atau
   `0000`. Package `flutter_blue_classic` yang dipakai di sini cuma
   menghubungkan ke perangkat yang sudah ter-pairing, tidak menangani
   proses pairing itu sendiri.
9. Colok HP Android via USB (aktifkan USB debugging), lalu:
   ```bash
   flutter run
   ```
   **Wajib pakai HP fisik**, bukan emulator — emulator Android tidak
   punya radio Bluetooth sungguhan.

## Alur pakai app

1. Buka app -> pilih dongle OBD2 dari daftar perangkat yang sudah dipairing.
2. App otomatis: konek -> kirim urutan init ELM327 (`ATZ`, `ATE0`, `ATL0`,
   `ATS0`, `ATH0`, `ATSP0`) -> query PID mana saja yang didukung mobil
   (`0100`, `0120`, `0140`, dst) -> mulai polling semua PID yang punya rumus
   decode di `lib/models/obd_pid.dart`.
3. Dashboard menampilkan kartu per-PID: nilai terdekode + satuan, dan hex
   mentahnya di bawahnya.
4. Tombol pause/play di app bar untuk jeda/lanjut polling.
5. Menu titik tiga: buka **Terminal Mentah**, **Export JSON**, **Export
   CSV**, atau **Putuskan koneksi**.

## Soal posisi gigi transmisi (balik ke pertanyaan awal)

PID standar OBD2 (SAE J1979) **tidak mencakup gear position**. Kalau
mobilmu memancarkan data itu, biasanya lewat PID manufacturer-specific
(mode `21`/`22`) yang beda-beda tiap pabrikan dan tidak didokumentasikan
resmi. Karena itu app ini punya layar **Terminal Mentah**: kamu bisa
kirim command mentah apa saja (misalnya `2200XX` kalau sudah nemu PID-nya
dari forum/reverse-engineering komunitas untuk merek mobilmu spesifik),
lihat balasannya, lalu kalau sudah ketemu rumusnya tinggal tambahkan satu
entry baru ke `kStandardPids` di `lib/models/obd_pid.dart` supaya otomatis
ikut muncul di dashboard & ikut ter-polling terus-menerus.

## Menambah PID baru

Tinggal tambah satu `ObdPidDef` baru ke list `kStandardPids` di
`lib/models/obd_pid.dart`:

```dart
ObdPidDef(
  pid: 'XX',              // kode PID 2-digit hex
  name: 'Nama PID',
  unit: 'satuan',
  expectedBytes: 1,       // atau 2/4 sesuai spesifikasi PID-nya
  decode: (b) => b[0].toDouble(), // rumus sesuai spesifikasi PID
),
```

PID yang tidak ada di tabel ini tetap bisa dilihat respons mentahnya lewat
Terminal Mentah, tapi tidak otomatis ikut di-polling terus-menerus oleh
dashboard (supaya siklus polling tidak melebar ke PID yang belum kamu
verifikasi rumusnya).

## Data untuk diolah lebih lanjut

Tiap sample yang berhasil dipoll (timestamp, PID, nama, hex mentah, nilai
terdekode, satuan) disimpan di memori (maks. 20.000 baris terakhir, baris
lama otomatis dibuang) dan bisa diexport kapan saja lewat menu:

- **Export JSON** -> array of object, satu object per sample.
- **Export CSV** -> `timestamp,pid,name,raw_hex,decoded_value,unit`.

File ditulis ke folder dokumen internal app lalu langsung dibuka share
sheet Android, jadi tinggal pilih mau dikirim ke mana (Drive, email, WhatsApp
ke diri sendiri, dll) untuk diproses lebih lanjut (Python/Excel/apa saja).

## Keterbatasan yang perlu kamu tahu

- Polling satu PID per request secara berurutan (bukan multi-PID sekaligus
  dalam satu command) — ini paling kompatibel lintas klon ELM327, tapi
  refresh rate-nya dibatasi kecepatan respons Bluetooth (biasanya masih
  dapat beberapa sample per detik per PID, cukup untuk logging/monitoring,
  bukan untuk balap data real-time presisi tinggi).
- Parser respons ELM327 di `lib/services/obd_parser.dart` menangani kasus
  umum (single-frame response per PID). Sebagian mobil/protokol (terutama
  yang butuh multi-frame CAN untuk PID tertentu) mungkin butuh penyesuaian
  parser lebih lanjut.
- Rumus decode di tabel PID standar sudah sesuai spesifikasi SAE J1979 resmi,
  tapi tetap disarankan divalidasi silang dengan scan tool lain (mis. Torque)
  di mobil aslinya sebelum dipakai untuk keputusan penting.
