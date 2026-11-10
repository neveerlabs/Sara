import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AppLanguage { english, indonesian }

const _languagePreferenceKey = 'app_language';

class AppLanguageController {
  AppLanguageController._();

  static final ValueNotifier<AppLanguage> language =
      ValueNotifier(AppLanguage.english);
  static int _revision = 0;

  static Future<void> load() async {
    final revision = _revision;
    final preferences = await SharedPreferences.getInstance();
    if (revision != _revision) return;
    language.value = switch (preferences.getString(_languagePreferenceKey)) {
      'id' => AppLanguage.indonesian,
      _ => AppLanguage.english,
    };
  }

  static Future<void> set(AppLanguage value) async {
    final previous = language.value;
    final revision = ++_revision;
    language.value = value;
    try {
      final preferences = await SharedPreferences.getInstance();
      if (revision != _revision) return;
      final saved = await preferences.setString(
        _languagePreferenceKey,
        value == AppLanguage.indonesian ? 'id' : 'en',
      );
      if (!saved) throw StateError('Could not save the selected language.');
    } catch (_) {
      if (revision == _revision) language.value = previous;
      rethrow;
    }
  }
}

String appText(String english, {Map<String, Object?> values = const {}}) {
  var translated = AppLanguageController.language.value == AppLanguage.english
      ? english
      : _indonesian[english] ?? english;
  for (final entry in values.entries) {
    translated = translated.replaceAll('{${entry.key}}', '${entry.value}');
  }
  return translated;
}

const _indonesian = <String, String>{
  'Settings': 'Pengaturan',
  'Close settings': 'Tutup pengaturan',
  'PREFERENCES': 'PREFERENSI',
  'Personal': 'Personal',
  'Configure': 'Konfigurasi',
  'Configuration help': 'Bantuan konfigurasi',
  'Back to configuration': 'Kembali ke konfigurasi',
  'Set up Google Gemini': 'Menyiapkan Google Gemini',
  'Follow these steps to connect Sara to the Gemini API:':
      'Ikuti langkah berikut untuk menghubungkan Sara ke Gemini API:',
  'Open Google AI Studio and sign in to your Google account.':
      'Buka Google AI Studio dan masuk ke akun Google-mu.',
  'Create a Gemini API key from the API keys page.':
      'Buat Gemini API key dari halaman API keys.',
  'Copy the key, return to Configure, paste it into Gemini API keys, then select Add API key.':
      'Salin key, kembali ke Konfigurasi, tempel di bagian API key Gemini, lalu pilih Tambahkan API key.',
  'Sara stores the key in the Linux keyring. It is not stored with chat messages.':
      'Sara menyimpan key di keyring Linux. Key tidak disimpan bersama pesan chat.',
  'Open Google AI Studio': 'Buka Google AI Studio',
  'Could not open Google AI Studio: {error}':
      'Tidak dapat membuka Google AI Studio: {error}',
  'Data': 'Data',
  'Make Sara feel more like yours.': 'Buat Sara terasa lebih personal.',
  'What should Sara call you?': 'Sara sebaiknya memanggilmu apa?',
  'Your name': 'Namamu',
  'Save name': 'Simpan nama',
  'Message copied': 'Pesan disalin',
  'Code copied': 'Kode disalin',
  'Clear chat removes all local messages.':
      'Hapus chat akan menghapus semua pesan lokal.',
  'Enter an API key to add.': 'Masukkan API key yang ingin ditambahkan.',
  'Add API key': 'Tambahkan API key',
  'API key': 'API key',
  'Saving...': 'Menyimpan...',
  'Your preferences stay on this device.':
      'Preferensimu hanya tersimpan di perangkat ini.',
  'Language': 'Bahasa',
  'Choose the language used throughout Sara.':
      'Pilih bahasa yang digunakan di seluruh aplikasi Sara.',
  'English': 'English',
  'Indonesian': 'Indonesia',
  'Manage your local chat data.': 'Kelola data chat lokalmu.',
  'Sara’s autonomous life': 'Kehidupan otonom Sara',
  'Sara desktop app': 'Aplikasi desktop Sara',
  'Copy error details': 'Salin detail error',
  'Sara sent you a message': 'Sara mengirim pesan',
  'Sara shared something with you.': 'Sara membagikan sesuatu denganmu.',
  'Sara needs your approval': 'Sara memerlukan persetujuanmu',
  'Sara wants permission to run this terminal command:\n{command}':
      'Sara meminta izin untuk menjalankan perintah terminal ini:\n{command}',
  'Minimize': 'Minimalkan',
  'Maximize': 'Maksimalkan',
  'Restore': 'Pulihkan',
  'Close': 'Tutup',
  'Sara can reflect and sometimes start a chat while the app is open. Reflection summaries, inner life, and long-term goals stay in local storage; recent chat and selected summaries are sent to Gemini while she thinks. Provider limits apply.':
      'Sara bisa berefleksi dan sesekali memulai chat saat aplikasi terbuka. Ringkasan refleksi, kehidupan batin, dan tujuan jangka panjang disimpan lokal; chat terbaru dan ringkasan terpilih dikirim ke Gemini saat Sara berpikir. Batas dari penyedia tetap berlaku.',
  'Autonomous thinking failed: {error}':
      'Proses berpikir otonom gagal: {error}',
  'Could not update Sara’s autonomous life setting: {error}':
      'Tidak dapat mengubah pengaturan kehidupan otonom Sara: {error}',
  'Could not update Sara’s camera access setting: {error}':
      'Tidak dapat mengubah pengaturan akses kamera Sara: {error}',
  'Backup and restore': 'Cadangkan dan pulihkan',
  'Export or import your local data as a Sara JSON backup.':
      'Ekspor atau impor data lokal dalam backup JSON Sara.',
  'Import': 'Impor',
  'Export': 'Ekspor',
  'Export Sara backup': 'Ekspor backup Sara',
  'Import Sara backup': 'Impor backup Sara',
  'Backup exported successfully.': 'Backup berhasil diekspor.',
  'Backup imported successfully.': 'Backup berhasil diimpor.',
  'Could not export backup: {error}': 'Tidak dapat mengekspor backup: {error}',
  'Could not import backup: {error}': 'Tidak dapat mengimpor backup: {error}',
  'Backup was imported, but chat could not be refreshed: {error}':
      'Backup berhasil diimpor, tetapi chat tidak dapat dimuat ulang: {error}',
  'Attachment cleanup failed after backup import: {error}':
      'Pembersihan lampiran setelah impor backup gagal: {error}',
  'Wait for Sara to finish replying before exporting a backup.':
      'Tunggu Sara selesai membalas sebelum mengekspor backup.',
  'Wait for Sara to finish replying before importing a backup.':
      'Tunggu Sara selesai membalas sebelum mengimpor backup.',
  'Replace local data?': 'Ganti data lokal?',
  'Importing this backup replaces all local conversation data and personal name. Your Gemini API keys stay unchanged.':
      'Mengimpor backup ini akan mengganti semua data percakapan lokal dan nama personal. API key Gemini tetap seperti sekarang.',
  'Import backup': 'Impor backup',
  'Wait for response to finish': 'Tunggu balasan selesai',
  'Clear chat': 'Hapus chat',
  'Clear chat?': 'Hapus chat?',
  'Cancel': 'Batal',
  'Adjust your AI connection settings.': 'Atur koneksi AI-mu.',
  'Provider': 'Penyedia',
  'Model': 'Model',
  'Default': 'Bawaan',
  'Gemini API keys': 'API key Gemini',
  '{count} added': '{count} ditambahkan',
  'No API keys added yet. Sara cannot send messages without a key.':
      'Belum ada API key. Sara tidak dapat mengirim pesan tanpa API key.',
  'Add another API key': 'Tambahkan API key lain',
  'Paste Gemini API key': 'Tempel API key Gemini',
  'Keys are stored in the Linux keyring and rotated automatically when one fails.':
      'Key disimpan di keyring Linux dan otomatis diganti jika gagal.',
  'Remove API key?': 'Hapus API key?',
  'This API key will be removed from the desktop keyring.':
      'API key ini akan dihapus dari keyring desktop.',
  'Remove key': 'Hapus key',
  'Remove API key {index}': 'Hapus API key {index}',
  'Google Gemini': 'Google Gemini',
  'Gemini API': 'Gemini API',
  'Settings saved': 'Pengaturan disimpan',
  'Thinking...': 'Sedang berpikir...',
  'Preparing a reply...': 'Menyiapkan balasan...',
  'Scroll to bottom': 'Gulir ke bawah',
  'Retry message': 'Coba lagi',
  'Delete messages?': 'Hapus pesan?',
  'This message and every reply and branch after it will be permanently deleted.':
      'Pesan ini beserta semua balasan dan cabang setelahnya akan dihapus permanen.',
  'Delete': 'Hapus',
  'Copy': 'Salin',
  'Edit': 'Edit',
  'Copied': 'Tersalin',
  'Copy code': 'Salin kode',
  'Like': 'Suka',
  'Dislike': 'Tidak suka',
  'Speech': 'Bacakan',
  'Stop speech': 'Hentikan bacaan',
  'Preparing speech': 'Menyiapkan suara',
  'Speech playback failed: {error}': 'Gagal memutar suara: {error}',
  'Regenerate': 'Buat ulang',
  'Previous response': 'Balasan sebelumnya',
  'Next response': 'Balasan berikutnya',
  'Send message': 'Kirim pesan',
  'Send': 'Kirim',
  'Where your thoughts find a home...':
      'Ceritakan apa yang sedang kamu pikirkan...',
  'Add attachment': 'Tambahkan lampiran',
  'File unavailable': 'File tidak tersedia',
  'Vent': 'Curhat',
  'Unwind': 'Lanjutkan',
  'Drop files or media here to attach':
      'Lepaskan file atau media di sini untuk dilampirkan',
  'Camera': 'Kamera',
  'Capture photo': 'Ambil foto',
  'Close camera': 'Tutup kamera',
  'Waiting for camera.': 'Menunggu kamera.',
  'Camera preview stopped unexpectedly.':
      'Pratinjau kamera berhenti tiba-tiba.',
  'Could not open camera: {error}': 'Tidak dapat membuka kamera: {error}',
  'Camera preview failed: {error}': 'Pratinjau kamera gagal: {error}',
  'Could not close camera: {error}': 'Tidak dapat menutup kamera: {error}',
  'Could not save camera photo: {error}':
      'Tidak dapat menyimpan foto kamera: {error}',
  'Allow Sara to use the camera': 'Izinkan Sara menggunakan kamera',
  'When enabled, Sara may choose to view camera frames while the app is running, including when minimized or Settings is open. Frames are sent to Gemini for analysis and temporary cache files are deleted after analysis.':
      'Jika aktif, Sara dapat memilih melihat frame kamera selama aplikasi berjalan, termasuk saat diminimalkan atau Settings terbuka. Frame dikirim ke Gemini untuk dianalisis dan file cache sementara dihapus setelah analisis.',
  'Sara is looking through the camera': 'Sara sedang melihat melalui kamera',
  'Stop camera access': 'Hentikan akses kamera',
  'Allow this terminal command?': 'Izinkan perintah terminal ini?',
  'Running command': 'Perintah sedang berjalan',
  'Running command (All allow)': 'Perintah berjalan (Izinkan semua)',
  'Working directory': 'Folder kerja',
  'Terminal command history storage is unavailable.':
      'Penyimpanan riwayat perintah terminal tidak tersedia.',
  'Could not save terminal command history: {error}':
      'Tidak dapat menyimpan riwayat perintah terminal: {error}',
  'Allow': 'Izinkan',
  'Skip': 'Lewati',
  'All allow': 'Izinkan semua',
  'Stop': 'Hentikan',
  'Could not stop terminal command: {error}':
      'Tidak dapat menghentikan perintah terminal: {error}',
  'Photo': 'Foto',
  'File': 'File',
  'Choose photos or videos': 'Pilih foto atau video',
  'Choose files': 'Pilih file',
  'Close preview': 'Tutup pratinjau',
  'Rewind 5 seconds': 'Mundur 5 detik',
  'Forward 5 seconds': 'Maju 5 detik',
  'Pause': 'Jeda',
  'Play': 'Putar',
  'Pause video': 'Jeda video',
  'Play video': 'Putar video',
  'Attachment file not found.': 'File lampiran tidak ditemukan.',
  'Dropped file cannot be accessed.': 'File yang dilepas tidak dapat diakses.',
  'Gemini does not support this file: {name}.':
      'Gemini tidak mendukung file ini: {name}.',
  'Sensitive file cannot be uploaded: {name}.':
      'File sensitif tidak dapat diunggah: {name}.',
  'Could not read file location: {name}.':
      'Tidak dapat membaca lokasi file: {name}.',
  'What would you like to talk about?': 'Apa yang ingin kamu bahas?',
  'Write a question or idea. Sara is ready to help.':
      'Tulis pertanyaan atau ide. Sara siap membantu.',
  'Unsupported file format: {name}.': 'Format file tidak didukung: {name}.',
  'Could not read the clipboard: {error}':
      'Tidak dapat membaca clipboard: {error}',
  'File not found: {name}': 'File tidak ditemukan: {name}',
  'Could not select attachment: {error}':
      'Tidak dapat memilih lampiran: {error}',
  'Could not prepare edited message attachments: {error}':
      'Tidak dapat menyiapkan lampiran pesan edit: {error}',
  'Unable to copy message: {error}': 'Gagal menyalin pesan: {error}',
  'Unable to copy code: {error}': 'Gagal menyalin kode: {error}',
  'Message could not be saved: {error}': 'Pesan tidak dapat disimpan: {error}',
  'Could not save message: {error}': 'Gagal menyimpan pesan: {error}',
  'Could not save response feedback: {error}':
      'Gagal menyimpan masukan untuk balasan: {error}',
  'Liked': 'Disukai',
  'Disliked': 'Tidak disukai',
  'Unable to open video preview: {error}':
      'Pratinjau video tidak dapat dibuka: {error}',
  'Unable to play video preview: {error}':
      'Pratinjau video tidak dapat diputar: {error}',
  'Video cannot be played: {error}': 'Video tidak dapat diputar: {error}',
  'Add at least one Gemini API key in Settings.':
      'Tambahkan minimal satu API key Gemini di Pengaturan.',
  'All Gemini API keys failed.': 'Semua API key Gemini gagal.',
  'All available keys have been marked as failed. Check or replace a key in Settings.':
      'Semua key yang tersedia ditandai gagal. Periksa atau ganti key di Pengaturan.',
  'Unknown error.': 'Kesalahan tidak diketahui.',
  'Gemini model name is not configured.':
      'Nama model Gemini belum dikonfigurasi.',
  'Gemini returned HTTP {status}.': 'Gemini mengembalikan HTTP {status}.',
  'Gemini returned an invalid response.':
      'Gemini mengembalikan respons yang tidak valid.',
  'Gemini exceeded the tool-call limit.':
      'Gemini melampaui batas pemanggilan tool.',
  'Request failed ({type}).': 'Permintaan gagal ({type}).',
  'Error reading personal data: {error}':
      'Gagal membaca data personal: {error}',
  'Personal name removed.': 'Nama personal dihapus.',
  'Name saved.': 'Nama disimpan.',
  'Could not save personal name: {error}':
      'Gagal menyimpan nama personal: {error}',
  'All chat messages will be permanently deleted.':
      'Semua pesan chat akan dihapus permanen.',
  'Unknown saved provider. Using Gemini.':
      'Provider tersimpan tidak dikenal. Menggunakan Gemini.',
  'Could not read AI settings from the keyring: {error}':
      'Gagal membaca pengaturan AI dari keyring: {error}',
  'Model name cannot be empty.': 'Nama model tidak boleh kosong.',
  'That API key has already been added.': 'API key tersebut sudah ditambahkan.',
  'Gemini model saved.': 'Model Gemini disimpan.',
  'Gemini API key added to the desktop keyring.':
      'API key Gemini ditambahkan ke keyring desktop.',
  'Could not save Gemini settings: {error}':
      'Gagal menyimpan pengaturan Gemini: {error}',
  'Gemini API key removed from the desktop keyring.':
      'API key Gemini dihapus dari keyring desktop.',
  'Could not remove Gemini API key: {error}':
      'Gagal menghapus API key Gemini: {error}',
  'Local chat storage is not ready. Please try again shortly.':
      'Penyimpanan chat belum siap. Coba lagi sebentar.',
  'Could not remove expired attachment paths: {error}':
      'Gagal menghapus path lampiran kedaluwarsa: {error}',
  'Could not clean up attachment cache: {error}':
      'Gagal membersihkan cache lampiran: {error}',
  'Could not open local chat storage: {error}':
      'Gagal membuka penyimpanan chat lokal: {error}',
  'Message saved successfully.': 'Pesan berhasil disimpan.',
  'Could not save message. Tap retry to try again.':
      'Gagal menyimpan pesan. Tekan coba lagi untuk mengulang.',
  'Message and following history deleted.':
      'Pesan dan riwayat setelahnya dihapus.',
  'Could not delete message: {error}': 'Gagal menghapus pesan: {error}',
  'Could not switch conversation branch: {error}':
      'Gagal berpindah cabang percakapan: {error}',
  'Could not load previous branch replies: {error}':
      'Gagal memuat balasan cabang sebelumnya: {error}',
  'Regeneration failed: {error}': 'Gagal membuat ulang balasan: {error}',
  'Messages deleted, but copied attachment cleanup failed: {error}':
      'Pesan terhapus, tetapi file lampiran hasil salin gagal dibersihkan: {error}',
  'Reply is ready. Tap retry to save it.':
      'Balasan tersedia. Tekan coba lagi untuk menyimpannya.',
  'Wait for Sara to finish replying before clearing the chat.':
      'Tunggu Sara selesai membalas sebelum menghapus chat.',
  'Chat deleted successfully.': 'Chat berhasil dihapus.',
  'Could not delete chat: {error}': 'Gagal menghapus chat: {error}',
  'Chat cleared, but copied attachment cleanup failed: {error}':
      'Chat terhapus, tetapi file lampiran hasil salin gagal dibersihkan: {error}',
  'Could not save selected language: {error}':
      'Gagal menyimpan bahasa yang dipilih: {error}',
  'Your language preference is saved on this device.':
      'Preferensi bahasa hanya tersimpan di perangkat ini.',
  'Language changed to {language}.': 'Bahasa diubah ke {language}.',
  'Could not add attachment: {error}':
      'Tidak dapat menambahkan lampiran: {error}',
  'No response needed.': 'Tidak perlu membalas.',
  'Reply is ready, but could not be saved: {error}':
      'Balasan sudah tersedia, tetapi tidak dapat disimpan: {error}',
  'Could not save conversation memory: {error}':
      'Tidak dapat menyimpan kenangan percakapan: {error}',
  'Could not save Sara’s inner-life state: {error}':
      'Tidak dapat menyimpan keadaan batin Sara: {error}',
  'Request failed: {error}': 'Permintaan gagal: {error}',
  'Request failed: {error}. The SQL message was not removed: {cleanupError}':
      'Permintaan gagal: {error}. Pesan SQL tidak dapat dihapus: {cleanupError}',
  'AI request failed: {error}. Tap retry beside the message to try again.':
      'Permintaan AI gagal: {error}. Tekan coba lagi di samping pesan.',
  'Request failed and the message row was not removed: {error}':
      'Permintaan gagal dan baris pesan tidak dapat dihapus: {error}',
};
