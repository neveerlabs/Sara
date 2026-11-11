<div align="center">
	<b>Sara</b>
	<p>Sara adalah aplikasi chat desktop (Linux) untuk obrolan pribadi—teman dekat yang siap menemani</p>
</div>

<p align="center">
  <a href="https://github.com/neveerlabs/Sara/releases/latest">
    <img src="https://img.shields.io/badge/Download%20app%20-blue?style=for-the-badge" alt="Download app">
  </a>
</p>

## Fitur

- Chat AI dengan Gemini, data dan percakapan disimpan lokal.
- Kirim gambar / file, serta pindai barcode dari gambar.
- Bacakan balasan (speech), ekspor/impor backup, dan kelola cabang percakapan (parrent message).
- Run commmand linux dengan bash user

## Tool AI

Sara dapat membaca lampiran, menganalisis gambar dari kamera (opsional), memindai barcode, mencari dan menyimpan kenangan dari obrolan, serta mencari riwayat command. Bash command hanya dijalankan setelah persetujuan pengguna yg muncul dicomposer.

## Tampilan

| Obrolan | Pengaturan |
|---|---|
| ![Tampilan obrolan Sara](https://raw.githubusercontent.com/neveerlabs/Sara/main/assets/screenshot/home.png) | ![Pengaturan Sara](https://raw.githubusercontent.com/neveerlabs/Sara/main/assets/screenshot/settings.png) |

## Privasi

Semua data riwayat, pesan dan lainnya disimpan lokal, sementara API key disimpan di keyring linux. Pesan dikirim ke Google Gemini untuk menghasilkan balasan.

## Catatan

* Data lampiran file / media (dari Camera / Clipboard) dihapus otomatis setelah 24 jam
* API Key disimpan di `keyring` Linux (bukan didatabase)
* Fitur **Text to Speech** (speech) menggunakan **Sound of Text**
* Provider yg digunakan hanya **Gemini** dan model yg digunakannya `gemini-3.5-flash-lite`
* Jika tombol **`Sara's autonomous life`** diaktifkan, AI dapat berfikir dilatar belakang (diluar pesan user)
* Jika tombol **`Allow Sara to use the camera`** diaktifkan, AI dapat mengambil gambar dari Kamera device secara otomatis
* Tombol like, dislike atau reaction disimpan untuk feedback AI
* Jika mode **Vent** aktif, maka pesan user tidak akan dikirim ke Gemini, tetapi tetap disimpan kedalam database
* Jika terjadi error/kegagalan saat kirim pesan (baik dari Gemini atau di SQL database), maka data pesannya tidak disimpan didatabase (cache support)
* Regenerate / Edit pesan akan membuat cabang baru untuk pesan tersebut
* Cabang pesan yg aktif / dibuka disimpan didatabase
* Hapus pesan user akan menghapus semua cabang dan pesan user tersebut,balasan AI (beserta cabangnya jika ada), dan semua pesan setelahnya