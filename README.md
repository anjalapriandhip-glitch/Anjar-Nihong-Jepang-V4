# NihonGo Master Ultimate v4

Aplikasi belajar bahasa Jepang Flutter dengan content pack JLPT N5-N1, SRS, stroke order, listening, speaking, pronunciation, grammar, dan AI Sensei personal.

## Fitur utama
- **Ribuan vocabulary JLPT N5-N1** dari OpenJLPT.
- **Ribuan kanji JLPT** dengan readings, meanings, stroke count, radical, dan contoh kata.
- **526 grammar points** N5-N1 dari OpenJLPT.
- **Stroke order** offline menggunakan SVG KanjiVG.
- **SRS / Anki-style review** dengan interval adaptif, ease, lapses, due cards.
- **Listening** menggunakan text-to-speech Jepang.
- **Speaking** menggunakan speech-to-text Android dan skor kemiripan sederhana.
- **Pronunciation practice** per kata.
- **AI Sensei** yang memasukkan daftar kesalahan terbanyak pengguna ke system prompt agar latihan bisa dipersonalisasi.
- Progress, favorit, XP, streak, dan statistik tersimpan lokal.

## Content build
Repository sengaja tidak menyimpan ribuan file dictionary di git. GitHub Actions menjalankan `tool/build_content.py` saat build:

1. Mengambil OpenJLPT.
2. Menggabungkan N5-N1 menjadi `assets/data/vocab.json`, `kanji.json`, `grammar.json`.
3. Mengambil KanjiVG.
4. Menyalin SVG stroke-order hanya untuk kanji yang dipakai.
5. Membuild APK release.

Dengan begitu `Actions` tidak lagi hanya membuild starter pack: setiap build mendapatkan content pack besar terbaru dari sumbernya.

## Lisensi data
OpenJLPT: CC BY-SA 4.0. KanjiVG: CC BY-SA 3.0. Lihat `assets/data/NOTICE.txt` setelah content build untuk atribusi.

Catatan: level JLPT pada OpenJLPT adalah perkiraan berbasis daftar komunitas karena JLPT tidak menerbitkan daftar kosakata/kanji resmi terkini.

## AI
Untuk aplikasi publik, jangan menanam API key OpenAI di APK. Gunakan backend/proxy yang mengamankan secret. Mode demo tetap bekerja tanpa API.
