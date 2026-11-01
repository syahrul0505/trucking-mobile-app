# Precision Trucking & Driver Tracking - Flutter Mobile Wrapper

Aplikasi Mobile Android (Flutter WebView) untuk sistem operasional logistik & tracking armada **Precision Logistik International** (`https://trucking.saleslog-pro.com/`).

---

## 🌟 Fitur Utama
1. **High-Accuracy GPS Bridge**:
   - Terintegrasi langsung dengan Geolocation HTML5 pada halaman `track-live.blade.php`.
   - Mengizinkan browser WebView membaca koordinat supir secara presisi tanpa popup berulang.
2. **Camera & Gallery Picker**:
   - Supir dapat langsung mengambil foto bukti struk bensin / nota tambal ban melalui kamera HP dan otomatis terkompresi.
3. **Smart URL Handler**:
   - Link WhatsApp, Telpon supir (`tel:`), dan navigasi Google Maps (`maps.google.com`) otomatis dibuka di aplikasi native luar.
4. **Pull to Refresh & Offline Fallback Screen**:
   - Swipe ke bawah untuk me-refresh data surat jalan.
   - Tampilan ramah pengguna jika sinyal internet HP di jalan sedang hilang/mati.

---

## 🚀 Cara Build Menjadi File APK

### Syarat
1. Pasang Flutter SDK (v3.0.0 atau lebih baru).
2. Android Studio atau Android SDK Build-Tools.

### Langkah Build:
1. Masuk ke direktori aplikasi:
   ```bash
   cd C:/laragon/www/trucking_flutter_app
   ```
2. Ambil semua dependencies:
   ```bash
   flutter pub get
   ```
3. Build file APK:
   ```bash
   flutter build apk --release
   ```
4. File APK siap install akan berada di:
   `build/app/outputs/flutter-apk/app-release.apk`
