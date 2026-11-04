import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_spinkit/flutter_spinkit.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:latlong2/latlong.dart';
import 'package:permission_handler/permission_handler.dart' as ph;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

const String kAppVersion = '1.5.1';
const int kAppVersionCode = 11;

// ============================================================
// DESIGN TOKENS
// ============================================================
class C {
  static const navy = Color(0xFF0B1B3A);
  static const navy2 = Color(0xFF1B3A73);
  static const primary = Color(0xFF2563EB);
  static const accent = Color(0xFFF59E0B);
  static const bg = Color(0xFFF3F5F9);
  static const border = Color(0xFFE4E8EF);
  static const text = Color(0xFF0F172A);
  static const muted = Color(0xFF64748B);
  static const green = Color(0xFF16A34A);
  static const red = Color(0xFFDC2626);
}

TextStyle t(double size, {FontWeight w = FontWeight.w500, Color c = C.text, double ls = 0, double? h}) =>
    GoogleFonts.plusJakartaSans(fontSize: size, fontWeight: w, color: c, letterSpacing: ls, height: h);

const List<BoxShadow> kShadow = [
  BoxShadow(color: Color(0x140F172A), blurRadius: 24, offset: Offset(0, 8)),
];

const LinearGradient kHeaderGradient =
    LinearGradient(colors: [C.navy, C.navy2], begin: Alignment.topLeft, end: Alignment.bottomRight);

String fmtDate(dynamic s) {
  if (s == null) return '-';
  final d = DateTime.tryParse(s.toString());
  if (d == null) return s.toString();
  const m = ['Jan', 'Feb', 'Mar', 'Apr', 'Mei', 'Jun', 'Jul', 'Agu', 'Sep', 'Okt', 'Nov', 'Des'];
  return '${d.day} ${m[d.month - 1]} ${d.year}';
}

String todayLabel() {
  final d = DateTime.now();
  const days = ['Senin', 'Selasa', 'Rabu', 'Kamis', 'Jumat', 'Sabtu', 'Minggu'];
  const m = ['Januari', 'Februari', 'Maret', 'April', 'Mei', 'Juni', 'Juli', 'Agustus', 'September', 'Oktober', 'November', 'Desember'];
  return '${days[d.weekday - 1]}, ${d.day} ${m[d.month - 1]} ${d.year}';
}

String greeting() {
  final h = DateTime.now().hour;
  if (h < 11) return 'Pagi';
  if (h < 15) return 'Siang';
  if (h < 18) return 'Sore';
  return 'Malam';
}

String rupiah(num v) {
  final s = v.round().toString();
  final b = StringBuffer();
  for (int i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write('.');
    b.write(s[i]);
  }
  return 'Rp $b';
}

void snack(BuildContext ctx, String msg, {Color color = C.text}) {
  ScaffoldMessenger.of(ctx)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(msg, style: t(13, w: FontWeight.w600, c: Colors.white)),
      backgroundColor: color,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ));
}

// ============================================================
// API CLIENT
// ============================================================
class AuthExpired implements Exception {
  const AuthExpired();
}

class Api {
  static const base = 'https://trucking.saleslog-pro.com/api/driver';

  static Future<String> token() async =>
      (await SharedPreferences.getInstance()).getString('auth_token') ?? '';

  static Map<String, dynamic> _decode(http.Response res) {
    if (res.statusCode == 401) throw const AuthExpired();
    final data = jsonDecode(res.body);
    if (data is Map<String, dynamic>) return data;
    throw Exception('Respon server tidak valid');
  }

  static Future<Map<String, dynamic>> get(String path) async {
    final tk = await token();
    final res = await http.get(
      Uri.parse('$base$path'),
      headers: {'Authorization': 'Bearer $tk', 'Accept': 'application/json'},
    ).timeout(const Duration(seconds: 20));
    return _decode(res);
  }

  static Future<Map<String, dynamic>> post(String path, Map<String, dynamic> body, {bool auth = true}) async {
    final headers = {'Content-Type': 'application/json', 'Accept': 'application/json'};
    if (auth) headers['Authorization'] = 'Bearer ${await token()}';
    final res = await http
        .post(Uri.parse('$base$path'), headers: headers, body: jsonEncode(body))
        .timeout(const Duration(seconds: 20));
    if (!auth) {
      final data = jsonDecode(res.body);
      if (data is Map<String, dynamic>) return data;
      throw Exception('Respon server tidak valid');
    }
    return _decode(res);
  }

  static Future<Map<String, dynamic>> delete(String path) async {
    final tk = await token();
    final res = await http.delete(
      Uri.parse('$base$path'),
      headers: {'Authorization': 'Bearer $tk', 'Accept': 'application/json'},
    ).timeout(const Duration(seconds: 20));
    return _decode(res);
  }
}

Future<void> logoutAndExit(BuildContext context) async {
  await Tracker.I.stop();
  try {
    await Api.post('/logout', {});
  } catch (_) {}
  final prefs = await SharedPreferences.getInstance();
  await prefs.clear();
  Tracker.I.selected = null;
  if (!context.mounted) return;
  Navigator.of(context).pushAndRemoveUntil(
    MaterialPageRoute(builder: (_) => const LoginScreen()),
    (_) => false,
  );
}

// ============================================================
// GPS TRACKER (singleton, tetap jalan saat pindah tab)
// ============================================================
class Tracker extends ChangeNotifier {
  Tracker._();
  static final Tracker I = Tracker._();

  final Battery _battery = Battery();

  Map<String, dynamic>? selected; // trip yang tampil di halaman GPS
  Map<String, dynamic>? tracking; // trip yang sedang dikirim lokasinya
  bool get isActive => tracking != null;

  Position? position;
  double speedKmh = 0;
  int battery = -1;
  int pings = 0;
  int failed = 0;
  String lastSync = '-';
  final List<LatLng> trail = [];

  StreamSubscription<Position>? _sub;
  Timer? _timer;
  bool _sending = false;

  bool isTracking(Map<String, dynamic>? trip) =>
      trip != null && tracking != null && tracking!['id'] == trip['id'];

  void select(Map<String, dynamic> trip) {
    selected = trip;
    notifyListeners();
  }

  Future<String?> start(Map<String, dynamic> trip) async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      return 'GPS HP belum aktif. Nyalakan Lokasi di pengaturan HP.';
    }
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
      return 'Izin lokasi ditolak. Aktifkan izin Lokasi untuk aplikasi ini.';
    }
    try {
      await ph.Permission.notification.request();
    } catch (_) {}

    await stop(notify: false);
    tracking = trip;
    selected = trip;
    pings = 0;
    failed = 0;
    lastSync = '-';
    trail.clear();

    final LocationSettings settings = defaultTargetPlatform == TargetPlatform.android
        ? AndroidSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 5,
            intervalDuration: const Duration(seconds: 5),
            foregroundNotificationConfig: const ForegroundNotificationConfig(
              notificationTitle: 'Precision Driver - GPS Aktif',
              notificationText: 'Lokasi perjalanan sedang dikirim ke kantor',
              enableWakeLock: true,
            ),
          )
        : const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 5);

    _sub = Geolocator.getPositionStream(locationSettings: settings).listen(_onPos, onError: (_) {});
    _timer = Timer.periodic(const Duration(seconds: 15), (_) => _ping());

    try {
      _onPos(await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 15)),
      ));
    } catch (_) {}
    _ping();
    notifyListeners();
    return null;
  }

  void _onPos(Position p) {
    position = p;
    speedKmh = p.speed < 0 ? 0 : (p.speed * 3.6).clamp(0, 160).toDouble();
    trail.add(LatLng(p.latitude, p.longitude));
    if (trail.length > 3000) trail.removeAt(0);
    notifyListeners();
  }

  Future<void> _ping() async {
    final trip = tracking;
    final p = position;
    if (trip == null || p == null || _sending) return;
    _sending = true;
    try {
      battery = await _battery.batteryLevel;
    } catch (_) {}
    try {
      final data = await Api.post('/trucking/${trip['id']}/ping', {
        'latitude': p.latitude,
        'longitude': p.longitude,
        'accuracy': p.accuracy,
        'speed': speedKmh,
        'heading': p.heading,
        'battery': battery >= 0 ? battery : null,
      });
      if (data['success'] == true) {
        pings++;
        failed = 0;
        lastSync = (data['time'] ?? '-').toString();
      } else {
        failed++;
      }
    } catch (_) {
      failed++;
    }
    _sending = false;
    notifyListeners();
  }

  Future<void> stop({bool notify = true}) async {
    await _sub?.cancel();
    _sub = null;
    _timer?.cancel();
    _timer = null;
    tracking = null;
    speedKmh = 0;
    if (notify) notifyListeners();
  }
}

// ============================================================
// APP
// ============================================================
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: Colors.white,
    systemNavigationBarIconBrightness: Brightness.dark,
  ));
  runApp(const DriverApp());
}

class DriverApp extends StatelessWidget {
  const DriverApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Precision Driver',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: C.bg,
        colorScheme: ColorScheme.fromSeed(seedColor: C.primary, primary: C.primary, surface: Colors.white),
        textTheme: GoogleFonts.plusJakartaSansTextTheme(),
      ),
      home: const SplashScreen(),
    );
  }
}

// ============================================================
// SPLASH
// ============================================================
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    await Future.delayed(const Duration(milliseconds: 900));
    final tk = await Api.token();
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => tk.isNotEmpty ? const MainShell() : const LoginScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        width: double.infinity,
        decoration: const BoxDecoration(gradient: kHeaderGradient),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const AppLogo(size: 84),
            const SizedBox(height: 22),
            Text('PRECISION DRIVER', style: t(22, w: FontWeight.w800, c: Colors.white, ls: 2)),
            const SizedBox(height: 6),
            Text('Aplikasi GPS Perjalanan Supir', style: t(13, c: Colors.white70)),
            const SizedBox(height: 40),
            const SpinKitThreeBounce(color: C.accent, size: 22),
          ],
        ),
      ),
    );
  }
}

class AppLogo extends StatelessWidget {
  final double size;
  const AppLogo({super.key, this.size = 64});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      padding: EdgeInsets.all(size * 0.15),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(size * 0.28),
        boxShadow: const [
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 20,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: Image.asset(
        'assets/images/precision_logo.png',
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => Icon(
          Icons.local_shipping_rounded,
          color: C.navy,
          size: size * 0.5,
        ),
      ),
    );
  }
}

// ============================================================
// LOGIN
// ============================================================
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _login = TextEditingController();
  final _password = TextEditingController();
  bool _loading = false;
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _login.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final login = _login.text.trim();
    final password = _password.text;
    if (login.isEmpty || password.isEmpty) {
      setState(() => _error = 'Isi username/email dan password.');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await Api.post('/login', {'login': login, 'password': password}, auth: false);
      if (data['success'] == true) {
        final user = (data['user'] as Map<String, dynamic>?) ?? {};
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('auth_token', data['token'].toString());
        await prefs.setString('user_name', (user['fullname'] ?? user['username'] ?? 'Supir').toString());
        await prefs.setString('user_username', (user['username'] ?? '').toString());
        await prefs.setString('user_phone', (user['phone'] ?? '').toString());
        await prefs.setString('user_email', (user['email'] ?? '').toString());
        if (!mounted) return;
        Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const MainShell()));
      } else {
        setState(() => _error = (data['message'] ?? 'Login gagal. Periksa kembali akun Anda.').toString());
      }
    } catch (_) {
      setState(() => _error = 'Koneksi gagal. Pastikan internet HP aktif.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  InputDecoration _deco(String hint, IconData icon, {Widget? suffix}) => InputDecoration(
        hintText: hint,
        hintStyle: t(14, c: const Color(0xFF94A3B8)),
        prefixIcon: Icon(icon, color: C.muted),
        suffixIcon: suffix,
        filled: true,
        fillColor: C.bg,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: C.border)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: C.primary, width: 1.6)),
      );

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.of(context).padding.top;
    return Scaffold(
      backgroundColor: C.bg,
      body: SingleChildScrollView(
        child: Column(
          children: [
            Container(
              width: double.infinity,
              padding: EdgeInsets.fromLTRB(28, top + 48, 28, 84),
              decoration: const BoxDecoration(
                gradient: kHeaderGradient,
                borderRadius: BorderRadius.only(bottomLeft: Radius.circular(36), bottomRight: Radius.circular(36)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const AppLogo(size: 60),
                  const SizedBox(height: 26),
                  Text('Selamat Datang', style: t(28, w: FontWeight.w800, c: Colors.white)),
                  const SizedBox(height: 8),
                  Text('Masuk untuk mulai perjalanan dan kirim lokasi GPS ke kantor.',
                      style: t(14, c: Colors.white70, h: 1.45)),
                ],
              ),
            ),
            Transform.translate(
              offset: const Offset(0, -48),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Container(
                  padding: const EdgeInsets.all(22),
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(26), boxShadow: kShadow),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Login Supir', style: t(18, w: FontWeight.w800)),
                      const SizedBox(height: 18),
                      if (_error != null)
                        Container(
                          width: double.infinity,
                          margin: const EdgeInsets.only(bottom: 16),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: C.red.withOpacity(0.08),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: C.red.withOpacity(0.25)),
                          ),
                          child: Row(children: [
                            const Icon(Icons.error_outline_rounded, color: C.red, size: 20),
                            const SizedBox(width: 10),
                            Expanded(child: Text(_error!, style: t(13, w: FontWeight.w600, c: C.red))),
                          ]),
                        ),
                      Text('Username / Email', style: t(13, w: FontWeight.w700, c: C.muted)),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _login,
                        style: t(15, w: FontWeight.w600),
                        textInputAction: TextInputAction.next,
                        decoration: _deco('contoh: ramdan', Icons.person_outline_rounded),
                      ),
                      const SizedBox(height: 16),
                      Text('Password', style: t(13, w: FontWeight.w700, c: C.muted)),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _password,
                        obscureText: _obscure,
                        style: t(15, w: FontWeight.w600),
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => _submit(),
                        decoration: _deco('••••••••', Icons.lock_outline_rounded,
                            suffix: IconButton(
                              icon: Icon(_obscure ? Icons.visibility_off_outlined : Icons.visibility_outlined, color: C.muted),
                              onPressed: () => setState(() => _obscure = !_obscure),
                            )),
                      ),
                      const SizedBox(height: 26),
                      SizedBox(
                        width: double.infinity,
                        height: 58,
                        child: ElevatedButton(
                          onPressed: _loading ? null : _submit,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: C.primary,
                            foregroundColor: Colors.white,
                            disabledBackgroundColor: C.primary.withOpacity(0.6),
                            elevation: 0,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                          ),
                          child: _loading
                              ? const SpinKitThreeBounce(color: Colors.white, size: 20)
                              : Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                                  Text('MASUK', style: t(16, w: FontWeight.w800, c: Colors.white, ls: 1)),
                                  const SizedBox(width: 8),
                                  const Icon(Icons.arrow_forward_rounded, size: 22),
                                ]),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Text('PT. Precision Logistik International', style: t(12, w: FontWeight.w600, c: C.muted)),
            const SizedBox(height: 4),
            Text('Versi $kAppVersion', style: t(11, c: const Color(0xFF94A3B8))),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// MAIN SHELL (BOTTOM NAV)
// ============================================================
class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _index = 0;
  final _dashKey = GlobalKey<DashboardPageState>();
  final _historyKey = GlobalKey<HistoryPageState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkForUpdate();
    });
  }

  Future<void> _checkForUpdate() async {
    try {
      final res = await http.get(
        Uri.parse('${Api.base}/app-version'),
        headers: {'Accept': 'application/json'},
      ).timeout(const Duration(seconds: 10));

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        if (data is Map && data['success'] == true) {
          final serverCode = (data['version_code'] as num?)?.toInt() ?? 0;
          final serverVer = data['latest_version'] ?? 'Terbaru';
          final notes = data['release_notes'] ?? 'Pembaruan aplikasi telah tersedia.';
          final downloadUrl = data['download_url'] ?? 'https://trucking.saleslog-pro.com/PrecisionDriver.apk';
          final forceUpdate = data['force_update'] == true;

          if (serverCode > kAppVersionCode && mounted) {
            _showUpdateDialog(
              version: serverVer.toString(),
              notes: notes.toString(),
              downloadUrl: downloadUrl.toString(),
              forceUpdate: forceUpdate,
            );
          }
        }
      }
    } catch (_) {}
  }

  void _showUpdateDialog({
    required String version,
    required String notes,
    required String downloadUrl,
    required bool forceUpdate,
  }) {
    showDialog(
      context: context,
      barrierDismissible: !forceUpdate,
      builder: (ctx) => PopScope(
        canPop: !forceUpdate,
        child: AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: C.primary.withOpacity(0.12),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.system_update_rounded, color: C.primary, size: 24),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text('Pembaruan Tersedia', style: t(17, w: FontWeight.w800)),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: C.green.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text('Versi $version', style: t(12, w: FontWeight.w800, c: C.green)),
              ),
              const SizedBox(height: 12),
              Text(notes, style: t(13.5, c: C.muted, h: 1.4)),
              const SizedBox(height: 14),
              Text(
                'Aplikasi akan mengunduh pembaruan. Anda tidak perlu uninstall aplikasi.',
                style: t(11.5, w: FontWeight.w600, c: C.primary),
              ),
            ],
          ),
          actions: [
            if (!forceUpdate)
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text('Nanti', style: t(14, w: FontWeight.w700, c: C.muted)),
              ),
            ElevatedButton(
              onPressed: () async {
                final uri = Uri.parse(downloadUrl);
                try {
                  await launchUrl(uri, mode: LaunchMode.externalApplication);
                } catch (_) {}
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: C.primary,
                foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              ),
              child: Text('PERBARUI SEKARANG', style: t(14, w: FontWeight.w800, c: Colors.white)),
            ),
          ],
        ),
      ),
    );
  }

  void _goGps(Map<String, dynamic>? trip) {
    if (trip != null) Tracker.I.select(trip);
    setState(() => _index = 1);
  }

  void _onTab(int i) {
    if (i == 0) _dashKey.currentState?.load();
    if (i == 2) _historyKey.currentState?.load();
    setState(() => _index = i);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Tracker.I,
      builder: (context, _) {
        final active = Tracker.I.isActive;
        return PopScope(
          canPop: _index == 0 && !active,
          onPopInvokedWithResult: (didPop, result) {
            if (didPop) return;
            if (_index != 0) {
              _onTab(0);
              return;
            }
            snack(context, 'GPS masih aktif. Tekan tombol Home HP untuk keluar tanpa mematikan GPS.', color: C.navy);
          },
          child: Scaffold(
            body: IndexedStack(
              index: _index,
              children: [
                DashboardPage(key: _dashKey, onOpenGps: _goGps),
                const GpsPage(),
                HistoryPage(key: _historyKey, onOpenGps: _goGps),
                const ProfilePage(),
              ],
            ),
            bottomNavigationBar: NavigationBar(
              selectedIndex: _index,
              onDestinationSelected: _onTab,
              backgroundColor: Colors.white,
              surfaceTintColor: Colors.white,
              indicatorColor: C.primary.withOpacity(0.12),
              height: 70,
              labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
              destinations: [
                const NavigationDestination(
                  icon: Icon(Icons.space_dashboard_outlined, color: C.muted),
                  selectedIcon: Icon(Icons.space_dashboard_rounded, color: C.primary),
                  label: 'Beranda',
                ),
                NavigationDestination(
                  icon: Badge(
                    isLabelVisible: active,
                    backgroundColor: C.green,
                    smallSize: 10,
                    child: const Icon(Icons.navigation_outlined, color: C.muted),
                  ),
                  selectedIcon: Badge(
                    isLabelVisible: active,
                    backgroundColor: C.green,
                    smallSize: 10,
                    child: const Icon(Icons.navigation_rounded, color: C.primary),
                  ),
                  label: 'GPS',
                ),
                const NavigationDestination(
                  icon: Icon(Icons.receipt_long_outlined, color: C.muted),
                  selectedIcon: Icon(Icons.receipt_long_rounded, color: C.primary),
                  label: 'Riwayat',
                ),
                const NavigationDestination(
                  icon: Icon(Icons.person_outline_rounded, color: C.muted),
                  selectedIcon: Icon(Icons.person_rounded, color: C.primary),
                  label: 'Akun',
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ============================================================
// SHARED WIDGETS
// ============================================================
class StatusBadge extends StatelessWidget {
  final dynamic status;
  final dynamic finishedAt;
  const StatusBadge(this.status, {super.key, this.finishedAt});

  @override
  Widget build(BuildContext context) {
    final s = (status ?? '').toString().toLowerCase();
    Color c = C.muted;
    String label = s.toUpperCase();
    final done = finishedAt != null && '$finishedAt'.isNotEmpty && s != 'rejected';
    if (done) {
      c = C.primary;
      label = 'SELESAI';
    } else if (s == 'approved') {
      c = C.green;
      label = 'DISETUJUI';
    } else if (s == 'pending') {
      c = const Color(0xFFD97706);
      label = 'MENUNGGU';
    } else if (s == 'rejected') {
      c = C.red;
      label = 'DITOLAK';
    } else if (s == 'done' || s == 'completed' || s == 'selesai') {
      c = C.primary;
      label = 'SELESAI';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(color: c.withOpacity(0.12), borderRadius: BorderRadius.circular(20)),
      child: Text(label, style: t(10.5, w: FontWeight.w800, c: c, ls: 0.4)),
    );
  }
}

class GpsPill extends StatelessWidget {
  final bool active;
  final bool dark;
  const GpsPill({super.key, required this.active, this.dark = false});

  @override
  Widget build(BuildContext context) {
    final c = active ? C.green : (dark ? Colors.white70 : C.muted);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: active ? C.green.withOpacity(dark ? 0.22 : 0.12) : (dark ? Colors.white.withOpacity(0.1) : C.bg),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: active ? const Color(0xFF22C55E) : c, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(active ? 'GPS AKTIF' : 'GPS MATI',
            style: t(11, w: FontWeight.w800, c: active && dark ? const Color(0xFF86EFAC) : c, ls: 0.5)),
      ]),
    );
  }
}

class PageHeader extends StatelessWidget {
  final String title;
  final String subtitle;
  const PageHeader({super.key, required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.of(context).padding.top;
    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(20, top + 18, 20, 24),
      decoration: const BoxDecoration(
        gradient: kHeaderGradient,
        borderRadius: BorderRadius.only(bottomLeft: Radius.circular(28), bottomRight: Radius.circular(28)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: t(22, w: FontWeight.w800, c: Colors.white)),
        const SizedBox(height: 4),
        Text(subtitle, style: t(13, c: Colors.white70)),
      ]),
    );
  }
}

class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String text;
  const EmptyState({super.key, required this.icon, required this.title, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(22), border: Border.all(color: C.border)),
      child: Column(children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: const BoxDecoration(color: C.bg, shape: BoxShape.circle),
          child: Icon(icon, color: C.muted, size: 30),
        ),
        const SizedBox(height: 12),
        Text(title, style: t(15, w: FontWeight.w800), textAlign: TextAlign.center),
        const SizedBox(height: 4),
        Text(text, style: t(12.5, c: C.muted, h: 1.4), textAlign: TextAlign.center),
      ]),
    );
  }
}

// ============================================================
// 1. DASHBOARD (BERANDA)
// ============================================================
class DashboardPage extends StatefulWidget {
  final void Function(Map<String, dynamic>?) onOpenGps;
  const DashboardPage({super.key, required this.onOpenGps});

  @override
  State<DashboardPage> createState() => DashboardPageState();
}

class DashboardPageState extends State<DashboardPage> {
  Map<String, dynamic>? _data;
  bool _loading = true;
  String? _error;
  String _name = 'Supir';

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      if (mounted) setState(() => _name = p.getString('user_name') ?? 'Supir');
    });
    load();
  }

  Future<void> load() async {
    setState(() {
      if (_data == null) _loading = true;
      _error = null;
    });
    try {
      final d = await Api.get('/dashboard');
      if (!mounted) return;
      final user = d['user'] as Map<String, dynamic>?;
      setState(() {
        _data = d;
        _loading = false;
        if (user != null) _name = (user['fullname'] ?? user['username'] ?? _name).toString();
      });
    } on AuthExpired {
      if (mounted) logoutAndExit(context);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Gagal memuat data. Tarik ke bawah untuk coba lagi.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final stats = (_data?['stats'] as Map<String, dynamic>?) ?? {};
    final service = (_data?['service'] as Map<String, dynamic>?) ?? {};
    final active = _data?['active_trip'] as Map<String, dynamic>?;
    final recent = (_data?['recent'] as List?) ?? [];

    return RefreshIndicator(
      onRefresh: load,
      color: C.primary,
      child: ListView(
        padding: EdgeInsets.zero,
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          _header(),
          Transform.translate(
            offset: const Offset(0, -40),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: _loading
                  ? Container(
                      height: 180,
                      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24), boxShadow: kShadow),
                      child: const Center(child: SpinKitThreeBounce(color: C.primary, size: 22)),
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (_error != null) ...[
                          EmptyState(icon: Icons.wifi_off_rounded, title: 'Tidak ada koneksi', text: _error!),
                          const SizedBox(height: 16),
                        ],
                        _activeTripCard(active),
                        const SizedBox(height: 22),
                        _sectionTitle('Ringkasan Perjalanan'),
                        const SizedBox(height: 12),
                        Row(children: [
                          Expanded(child: _statTile(Icons.today_rounded, C.primary, '${stats['trips_today'] ?? 0}', 'Trip Hari Ini')),
                          const SizedBox(width: 12),
                          Expanded(child: _statTile(Icons.calendar_month_rounded, const Color(0xFF7C3AED), '${stats['trips_month'] ?? 0}', 'Trip Bulan Ini')),
                        ]),
                        const SizedBox(height: 12),
                        Row(children: [
                          Expanded(child: _statTile(Icons.route_rounded, C.green, '${stats['km_today'] ?? 0}', 'KM Hari Ini')),
                          const SizedBox(width: 12),
                          Expanded(child: _statTile(Icons.speed_rounded, C.accent, '${stats['km_month'] ?? 0}', 'KM Bulan Ini')),
                        ]),
                        const SizedBox(height: 22),
                        _sectionTitle('Status Surat Jalan & Service'),
                        const SizedBox(height: 12),
                        _statusCard(stats, service),
                        const SizedBox(height: 22),
                        _sectionTitle('Surat Jalan Terakhir'),
                        const SizedBox(height: 12),
                        if (recent.isEmpty)
                          const EmptyState(icon: Icons.inbox_outlined, title: 'Belum ada data', text: 'Riwayat surat jalan akan tampil di sini.')
                        else
                          ...recent.map((e) => _recentTile(Map<String, dynamic>.from(e as Map))),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String s) => Text(s, style: t(16, w: FontWeight.w800));

  Widget _header() {
    final top = MediaQuery.of(context).padding.top;
    final initial = _name.isNotEmpty ? _name[0].toUpperCase() : 'S';
    return Container(
      padding: EdgeInsets.fromLTRB(20, top + 18, 12, 64),
      decoration: const BoxDecoration(
        gradient: kHeaderGradient,
        borderRadius: BorderRadius.only(bottomLeft: Radius.circular(32), bottomRight: Radius.circular(32)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            CircleAvatar(
              radius: 24,
              backgroundColor: C.accent,
              child: Text(initial, style: t(20, w: FontWeight.w800, c: C.navy)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Selamat ${greeting()},', style: t(13, c: Colors.white70)),
                Text(_name, maxLines: 1, overflow: TextOverflow.ellipsis, style: t(20, w: FontWeight.w800, c: Colors.white)),
              ]),
            ),
            IconButton(
              onPressed: load,
              icon: const Icon(Icons.refresh_rounded, color: Colors.white),
            ),
          ]),
          const SizedBox(height: 18),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Row(children: [
              const Icon(Icons.calendar_today_rounded, color: Colors.white60, size: 15),
              const SizedBox(width: 6),
              Expanded(child: Text(todayLabel(), style: t(12.5, w: FontWeight.w600, c: Colors.white70))),
              AnimatedBuilder(
                animation: Tracker.I,
                builder: (_, __) => GpsPill(active: Tracker.I.isActive, dark: true),
              ),
            ]),
          ),
        ],
      ),
    );
  }

  Widget _activeTripCard(Map<String, dynamic>? trip) {
    if (trip == null) {
      return Container(
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(24), boxShadow: kShadow),
        child: const EmptyState(
          icon: Icons.local_shipping_outlined,
          title: 'Belum ada perjalanan aktif',
          text: 'Surat jalan baru akan muncul di sini setelah dibuat admin.',
        ),
      );
    }
    return AnimatedBuilder(
      animation: Tracker.I,
      builder: (context, _) {
        final tracking = Tracker.I.isTracking(trip);
        return Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24), boxShadow: kShadow),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(color: C.primary.withOpacity(0.1), borderRadius: BorderRadius.circular(14)),
                  child: const Icon(Icons.local_shipping_rounded, color: C.primary),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('PERJALANAN AKTIF', style: t(10.5, w: FontWeight.w800, c: C.muted, ls: 1)),
                    const SizedBox(height: 2),
                    Text('${trip['nomor_surat_jalan'] ?? '-'}', style: t(16, w: FontWeight.w800)),
                  ]),
                ),
                StatusBadge(trip['status']),
              ]),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(color: C.bg, borderRadius: BorderRadius.circular(16)),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Icon(Icons.place_rounded, color: C.red, size: 22),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('Tujuan', style: t(11, w: FontWeight.w700, c: C.muted)),
                      const SizedBox(height: 2),
                      Text('${trip['consignee_name'] ?? '-'}', style: t(14, w: FontWeight.w800)),
                      if ((trip['consignee_address'] ?? '').toString().isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text('${trip['consignee_address']}', maxLines: 2, overflow: TextOverflow.ellipsis, style: t(12.5, c: C.muted)),
                      ],
                    ]),
                  ),
                ]),
              ),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(child: _infoChip(Icons.local_shipping_outlined, 'Plat', '${trip['nomor_polisi'] ?? '-'}')),
                const SizedBox(width: 8),
                Expanded(child: _infoChip(Icons.inventory_2_outlined, 'Qty', '${trip['qty'] ?? '-'}')),
                const SizedBox(width: 8),
                Expanded(child: _infoChip(Icons.event_rounded, 'Tanggal', fmtDate(trip['tanggal']))),
              ]),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                height: 58,
                child: ElevatedButton.icon(
                  onPressed: () => widget.onOpenGps(trip),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: tracking ? C.green : C.primary,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                  ),
                  icon: const Icon(Icons.navigation_rounded, size: 22),
                  label: Text(tracking ? 'GPS AKTIF - LIHAT PETA' : 'BUKA GPS PERJALANAN',
                      style: t(15, w: FontWeight.w800, c: Colors.white, ls: 0.5)),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _infoChip(IconData icon, String label, String value) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        decoration: BoxDecoration(border: Border.all(color: C.border), borderRadius: BorderRadius.circular(14)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, size: 13, color: C.muted),
            const SizedBox(width: 4),
            Text(label, style: t(10.5, w: FontWeight.w700, c: C.muted)),
          ]),
          const SizedBox(height: 4),
          Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: t(12.5, w: FontWeight.w800)),
        ]),
      );

  Widget _statTile(IconData icon, Color color, String value, String label) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20), border: Border.all(color: C.border)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(color: color.withOpacity(0.12), borderRadius: BorderRadius.circular(12)),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(height: 14),
          Text(value, style: t(24, w: FontWeight.w800)),
          const SizedBox(height: 2),
          Text(label, style: t(12, w: FontWeight.w600, c: C.muted)),
        ]),
      );

  Widget _statusCard(Map<String, dynamic> stats, Map<String, dynamic> service) {
    Widget col(String value, String label, Color color, IconData icon) => Expanded(
          child: Column(children: [
            Icon(icon, color: color, size: 22),
            const SizedBox(height: 6),
            Text(value, style: t(20, w: FontWeight.w800)),
            Text(label, textAlign: TextAlign.center, style: t(11, w: FontWeight.w600, c: C.muted)),
          ]),
        );
    final totalService = (service['total_month'] as num?) ?? 0;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20), border: Border.all(color: C.border)),
      child: Column(children: [
        IntrinsicHeight(
          child: Row(children: [
            col('${stats['pending'] ?? 0}', 'SJ Menunggu', const Color(0xFFD97706), Icons.hourglass_top_rounded),
            const VerticalDivider(color: C.border, width: 1),
            col('${stats['approved'] ?? 0}', 'SJ Disetujui', C.green, Icons.verified_rounded),
            const VerticalDivider(color: C.border, width: 1),
            col('${service['pending'] ?? 0}', 'Service Menunggu', C.primary, Icons.build_circle_outlined),
          ]),
        ),
        if (totalService > 0) ...[
          const SizedBox(height: 14),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(color: C.bg, borderRadius: BorderRadius.circular(12)),
            child: Row(children: [
              Expanded(child: Text('Biaya service disetujui bulan ini', style: t(12, w: FontWeight.w600, c: C.muted))),
              Text(rupiah(totalService), style: t(13, w: FontWeight.w800)),
            ]),
          ),
        ],
      ]),
    );
  }

  Widget _recentTile(Map<String, dynamic> e) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Material(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: () => widget.onOpenGps(e),
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(18), border: Border.all(color: C.border)),
              child: Row(children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(color: C.bg, borderRadius: BorderRadius.circular(12)),
                  child: const Icon(Icons.description_outlined, color: C.navy2, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${e['nomor_surat_jalan'] ?? '-'}', style: t(13.5, w: FontWeight.w800)),
                    const SizedBox(height: 2),
                    Text('${e['consignee_name'] ?? '-'}', maxLines: 1, overflow: TextOverflow.ellipsis, style: t(12, c: C.muted)),
                    Text('${fmtDate(e['tanggal'])}  •  ${e['nomor_polisi'] ?? '-'}', style: t(11, c: const Color(0xFF94A3B8))),
                  ]),
                ),
                StatusBadge(e['status'], finishedAt: e['finished_at']),
              ]),
            ),
          ),
        ),
      );
}

// ============================================================
// 2. GPS PERJALANAN
// ============================================================
class GpsPage extends StatefulWidget {
  const GpsPage({super.key});

  @override
  State<GpsPage> createState() => _GpsPageState();
}

class _GpsPageState extends State<GpsPage> {
  final MapController _map = MapController();
  bool _mapReady = false;
  bool _follow = true;
  bool _busy = false;
  bool _loadingTrips = true;
  List<Map<String, dynamic>> _trips = [];

  dynamic _loadedTripId;
  LatLng? _dest;
  LatLng? _idlePos;
  List<LatLng> _route = [];
  List<List<LatLng>> _history = [];
  List<Map<String, dynamic>> _tripExpenses = [];
  double? _routeKm;
  double? _routeMin;

  @override
  void initState() {
    super.initState();
    Tracker.I.addListener(_onTracker);
    _loadTrips();
  }

  @override
  void dispose() {
    Tracker.I.removeListener(_onTracker);
    super.dispose();
  }

  void _onTracker() {
    if (!mounted) return;
    final sel = Tracker.I.selected;
    if (sel != null && sel['id'] != _loadedTripId) _loadTripData(sel);
    final p = Tracker.I.position;
    if (_follow && _mapReady && p != null && Tracker.I.isTracking(sel)) {
      _map.move(LatLng(p.latitude, p.longitude), math.max(_map.camera.zoom, 15));
    }
    setState(() {});
  }

  Future<void> _loadTrips() async {
    setState(() => _loadingTrips = true);
    try {
      final d = await Api.get('/truckings');
      final list = ((d['truckings'] as List?) ?? []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
      if (!mounted) return;
      setState(() {
        _trips = list;
        _loadingTrips = false;
      });
      if (Tracker.I.selected != null && !list.any((e) => e['id'] == Tracker.I.selected!['id'])) {
        Tracker.I.selected = null;
      }
      if (Tracker.I.selected == null && list.isNotEmpty) {
        Tracker.I.select(list.first);
      } else if (Tracker.I.selected != null && Tracker.I.selected!['id'] != _loadedTripId) {
        _loadTripData(Tracker.I.selected!);
      }
    } on AuthExpired {
      if (mounted) logoutAndExit(context);
    } catch (_) {
      if (mounted) setState(() => _loadingTrips = false);
    }
  }

  LatLng? get _me {
    final p = Tracker.I.position;
    if (p != null && Tracker.I.isActive) return LatLng(p.latitude, p.longitude);
    if (_idlePos != null) return _idlePos;
    if (p != null) return LatLng(p.latitude, p.longitude);
    return null;
  }

  Future<void> _loadTripData(Map<String, dynamic> trip) async {
    final id = trip['id'];
    _loadedTripId = id;
    setState(() {
      _dest = null;
      _route = [];
      _history = [];
      _tripExpenses = [];
      _routeKm = null;
      _routeMin = null;
    });
    try {
      final d = await Api.get('/trucking/$id');
      final segs = _splitSegments((d['points'] as List?) ?? []);
      final exps = ((d['expenses'] as List?) ?? []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
      if (mounted && _loadedTripId == id) {
        setState(() {
          _history = segs;
          _tripExpenses = exps;
        });
      }
    } catch (_) {}
    _idlePos ??= await _oneShotPosition();
    await _geocode(trip);
    if (_loadedTripId != id) return;
    await _computeRoute();
    _fitAll();
  }

  /// Pecah titik GPS jadi beberapa segmen. Titik yang terpisah jauh (>1 km)
  /// atau jeda waktu lama (>5 menit, mis. GPS dimatikan) tidak disambung
  /// dengan garis lurus.
  List<List<LatLng>> _splitSegments(List raw) {
    const dist = Distance();
    final segs = <List<LatLng>>[];
    var cur = <LatLng>[];
    LatLng? prev;
    int? prevTs;
    for (final r in raw) {
      if (r is! Map || r['lat'] == null || r['lng'] == null) continue;
      final p = LatLng((r['lat'] as num).toDouble(), (r['lng'] as num).toDouble());
      final ts = (r['ts'] as num?)?.toInt();
      if (prev != null) {
        final gapM = dist.distance(prev, p);
        final gapS = (ts != null && prevTs != null) ? ts - prevTs : 0;
        if (gapM > 1000 || gapS > 300) {
          if (cur.length > 1) segs.add(cur);
          cur = <LatLng>[];
        }
      }
      cur.add(p);
      prev = p;
      prevTs = ts;
    }
    if (cur.length > 1) segs.add(cur);
    return segs;
  }

  Future<LatLng?> _oneShotPosition() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) return null;
      final last = await Geolocator.getLastKnownPosition();
      final p = last ??
          await Geolocator.getCurrentPosition(
            locationSettings: const LocationSettings(accuracy: LocationAccuracy.medium, timeLimit: Duration(seconds: 12)),
          );
      return LatLng(p.latitude, p.longitude);
    } catch (_) {
      return null;
    }
  }

  Future<void> _geocode(Map<String, dynamic> trip) async {
    final id = trip['id'];
    final addr = (trip['consignee_address'] ?? '').toString().trim();
    final name = (trip['consignee_name'] ?? '').toString().trim();
    final queries = <String>[
      if (addr.isNotEmpty && name.isNotEmpty) '$name, $addr',
      if (addr.isNotEmpty) addr,
      if (name.isNotEmpty) name,
    ];
    for (final q in queries) {
      try {
        final uri = Uri.https('nominatim.openstreetmap.org', '/search',
            {'q': q, 'format': 'json', 'limit': '1', 'countrycodes': 'id'});
        final res = await http.get(uri, headers: {
          'User-Agent': 'PrecisionDriverApp/$kAppVersion (trucking.saleslog-pro.com)',
        }).timeout(const Duration(seconds: 12));
        final list = jsonDecode(res.body);
        if (list is List && list.isNotEmpty) {
          final lat = double.tryParse('${list[0]['lat']}');
          final lon = double.tryParse('${list[0]['lon']}');
          if (lat != null && lon != null) {
            if (mounted && _loadedTripId == id) setState(() => _dest = LatLng(lat, lon));
            return;
          }
        }
      } catch (_) {}
    }
  }

  Future<void> _computeRoute() async {
    final from = _me;
    final to = _dest;
    if (from == null || to == null) return;
    try {
      final url = Uri.parse('https://router.project-osrm.org/route/v1/driving/'
          '${from.longitude},${from.latitude};${to.longitude},${to.latitude}?overview=full&geometries=geojson');
      final res = await http.get(url).timeout(const Duration(seconds: 15));
      final d = jsonDecode(res.body);
      final routes = d is Map ? d['routes'] as List? : null;
      if (routes != null && routes.isNotEmpty) {
        final r = routes[0] as Map;
        final coords = ((r['geometry'] as Map)['coordinates'] as List)
            .map((c) => LatLng(((c as List)[1] as num).toDouble(), (c[0] as num).toDouble()))
            .toList();
        if (mounted) {
          setState(() {
            _route = coords;
            _routeKm = (r['distance'] as num) / 1000;
            _routeMin = (r['duration'] as num) / 60;
          });
        }
      }
    } catch (_) {}
  }

  void _fitAll() {
    if (!_mapReady || !mounted) return;
    final me = _me;
    final pts = <LatLng>[if (me != null) me, if (_dest != null) _dest!, ..._route, for (final s in _history) ...s];
    if (pts.isEmpty) return;
    if (pts.length == 1) {
      _map.move(pts.first, 15);
      return;
    }
    _map.fitCamera(CameraFit.bounds(
      bounds: LatLngBounds.fromPoints(pts),
      padding: const EdgeInsets.fromLTRB(40, 170, 40, 340),
      maxZoom: 17,
    ));
  }

  void _recenter() {
    final me = _me;
    if (me == null || !_mapReady) {
      snack(context, 'Posisi HP belum terbaca. Pastikan GPS aktif.', color: C.navy);
      return;
    }
    setState(() => _follow = true);
    _map.move(me, 16);
  }

  Future<bool> _confirm(String title, String text, String okLabel, Color okColor) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: Text(title, style: t(18, w: FontWeight.w800)),
        content: Text(text, style: t(14, c: C.muted, h: 1.4)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('Batal', style: t(14, w: FontWeight.w700, c: C.muted))),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: okColor, foregroundColor: Colors.white, elevation: 0),
            child: Text(okLabel, style: t(14, w: FontWeight.w800, c: Colors.white)),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _toggle() async {
    final sel = Tracker.I.selected;
    if (sel == null) return;
    if (Tracker.I.isTracking(sel)) {
      if (await _confirm('Hentikan GPS?', 'Lokasi Anda tidak akan dikirim lagi ke kantor untuk perjalanan ini.', 'Hentikan', C.red)) {
        await Tracker.I.stop();
      }
      return;
    }
    if (Tracker.I.isActive) {
      final ok = await _confirm('Pindah perjalanan?',
          'GPS sedang aktif untuk ${Tracker.I.tracking?['nomor_surat_jalan']}. Pindahkan ke ${sel['nomor_surat_jalan']}?', 'Pindah', C.primary);
      if (!ok) return;
    }
    setState(() => _busy = true);
    final err = await Tracker.I.start(sel);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _follow = true;
    });
    if (err != null) {
      snack(context, err, color: C.red);
    } else {
      snack(context, 'GPS aktif. Lokasi dikirim otomatis tiap 15 detik.', color: C.green);
      _computeRoute();
    }
  }

  Future<void> _finishTrip() async {
    final sel = Tracker.I.selected;
    if (sel == null) return;
    final ok = await _confirm(
      'Selesaikan perjalanan?',
      'Pastikan barang sudah diterima di tujuan. GPS akan dimatikan dan surat jalan ${sel['nomor_surat_jalan']} ditandai SELESAI.',
      'Selesai',
      C.primary,
    );
    if (!ok) return;
    setState(() => _busy = true);
    try {
      final p = Tracker.I.position ?? await Geolocator.getLastKnownPosition();
      final body = <String, dynamic>{};
      if (p != null) {
        body['latitude'] = p.latitude;
        body['longitude'] = p.longitude;
        body['accuracy'] = p.accuracy;
      }
      if (Tracker.I.battery >= 0) body['battery'] = Tracker.I.battery;
      final d = await Api.post('/trucking/${sel['id']}/finish', body);
      if (d['success'] != true) throw Exception(d['message'] ?? 'Gagal');
      if (Tracker.I.isTracking(sel)) await Tracker.I.stop();
      Tracker.I.selected = null;
      _loadedTripId = null;
      if (!mounted) return;
      setState(() {
        _busy = false;
        _dest = null;
        _route = [];
        _history = [];
        _routeKm = null;
        _routeMin = null;
      });
      snack(context, '${d['message'] ?? 'Perjalanan selesai.'}', color: C.green);
      await _loadTrips();
    } on AuthExpired {
      if (mounted) logoutAndExit(context);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      snack(context, 'Gagal menyelesaikan perjalanan. Cek koneksi internet lalu coba lagi.', color: C.red);
    }
  }

  Future<void> _addExpenseModal() async {
    final sel = Tracker.I.selected;
    if (sel == null) return;

    String kat = 'bensin';
    final nomCtrl = TextEditingController();
    final ketCtrl = TextEditingController();
    XFile? pickedPhoto;
    bool isSubmitting = false;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setMState) => Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 20,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 44,
                    height: 5,
                    decoration: BoxDecoration(color: C.border, borderRadius: BorderRadius.circular(4)),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(color: C.accent.withOpacity(0.15), shape: BoxShape.circle),
                      child: const Icon(Icons.receipt_long_rounded, color: C.accent, size: 24),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Catat Bensin / Tol', style: t(17, w: FontWeight.w800)),
                          Text('${sel['nomor_surat_jalan']}', style: t(12, c: C.muted)),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                Text('Jenis Pengeluaran', style: t(13, w: FontWeight.w700, c: C.muted)),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: InkWell(
                        onTap: () => setMState(() => kat = 'bensin'),
                        borderRadius: BorderRadius.circular(14),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          decoration: BoxDecoration(
                            color: kat == 'bensin' ? C.accent.withOpacity(0.12) : C.bg,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: kat == 'bensin' ? C.accent : C.border, width: 2),
                          ),
                          child: Column(
                            children: [
                              const Icon(Icons.local_gas_station_rounded, color: C.accent, size: 26),
                              const SizedBox(height: 4),
                              Text('Bensin / BBM', style: t(13, w: FontWeight.w800, c: kat == 'bensin' ? C.accent : C.muted)),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: InkWell(
                        onTap: () => setMState(() => kat = 'tol'),
                        borderRadius: BorderRadius.circular(14),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          decoration: BoxDecoration(
                            color: kat == 'tol' ? C.primary.withOpacity(0.12) : C.bg,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: kat == 'tol' ? C.primary : C.border, width: 2),
                          ),
                          child: Column(
                            children: [
                              const Icon(Icons.toll_rounded, color: C.primary, size: 26),
                              const SizedBox(height: 4),
                              Text('Tiket / Tol', style: t(13, w: FontWeight.w800, c: kat == 'tol' ? C.primary : C.muted)),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text('Nominal Pengeluaran (Rp)', style: t(13, w: FontWeight.w700, c: C.muted)),
                const SizedBox(height: 6),
                TextField(
                  controller: nomCtrl,
                  keyboardType: TextInputType.number,
                  style: t(18, w: FontWeight.w800, c: C.primary),
                  decoration: InputDecoration(
                    prefixIcon: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text('Rp', style: t(16, w: FontWeight.w800, c: C.muted)),
                    ),
                    prefixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
                    hintText: '50.000',
                    filled: true,
                    fillColor: C.bg,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
                  ),
                ),
                const SizedBox(height: 16),
                Text('Foto Bukti / Struk Nota', style: t(13, w: FontWeight.w700, c: C.muted)),
                const SizedBox(height: 6),
                InkWell(
                  onTap: () async {
                    final picker = ImagePicker();
                    final source = await showModalBottomSheet<ImageSource>(
                      context: ctx,
                      backgroundColor: Colors.white,
                      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
                      builder: (bctx) => SafeArea(
                        child: Wrap(
                          children: [
                            ListTile(
                              leading: const Icon(Icons.camera_alt_rounded, color: C.primary),
                              title: const Text('Ambil Foto Kamera'),
                              onTap: () => Navigator.pop(bctx, ImageSource.camera),
                            ),
                            ListTile(
                              leading: const Icon(Icons.photo_library_rounded, color: C.accent),
                              title: const Text('Pilih dari Galeri'),
                              onTap: () => Navigator.pop(bctx, ImageSource.gallery),
                            ),
                          ],
                        ),
                      ),
                    );
                    if (source != null) {
                      final img = await picker.pickImage(source: source, maxWidth: 1400, imageQuality: 80);
                      if (img != null) {
                        setMState(() => pickedPhoto = img);
                      }
                    }
                  },
                  borderRadius: BorderRadius.circular(16),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: C.bg,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: pickedPhoto != null ? C.green : C.border, width: 2),
                    ),
                    child: pickedPhoto == null
                        ? Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(Icons.add_a_photo_rounded, color: C.primary, size: 22),
                              const SizedBox(width: 10),
                              Text('Ambil Foto Struk Nota', style: t(14, w: FontWeight.w700, c: C.primary)),
                            ],
                          )
                        : Row(
                            children: [
                              const Icon(Icons.check_circle_rounded, color: C.green, size: 24),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text('Foto struk terpilih: ${pickedPhoto!.name}',
                                    maxLines: 1, overflow: TextOverflow.ellipsis, style: t(13, w: FontWeight.w700, c: C.green)),
                              ),
                              const Icon(Icons.refresh_rounded, color: C.muted, size: 20),
                            ],
                          ),
                  ),
                ),
                const SizedBox(height: 16),
                Text('Keterangan / Lokasi (Opsional)', style: t(13, w: FontWeight.w700, c: C.muted)),
                const SizedBox(height: 6),
                TextField(
                  controller: ketCtrl,
                  decoration: InputDecoration(
                    hintText: 'Ex: SPBU Rest Area KM 57 / Gerbang Tol',
                    filled: true,
                    fillColor: C.bg,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
                  ),
                ),
                const SizedBox(height: 22),
                SizedBox(
                  width: double.infinity,
                  height: 54,
                  child: ElevatedButton(
                    onPressed: isSubmitting
                        ? null
                        : () async {
                            final rawNom = nomCtrl.text.replaceAll('.', '').replaceAll(',', '').trim();
                            final nom = double.tryParse(rawNom);
                            if (nom == null || nom <= 0) {
                              snack(context, 'Masukkan nominal pengeluaran yang valid.', color: C.red);
                              return;
                            }
                            if (pickedPhoto == null) {
                              snack(context, 'Wajib melampirkan foto struk/nota.', color: C.red);
                              return;
                            }
                            setMState(() => isSubmitting = true);
                            try {
                              final bytes = await pickedPhoto!.readAsBytes();
                              final b64 = base64Encode(bytes);
                              final res = await Api.post('/trucking/${sel['id']}/expense', {
                                'kategori': kat,
                                'nominal': nom,
                                'keterangan': ketCtrl.text.trim(),
                                'photo_base64': b64,
                              });
                              if (res['success'] == true) {
                                if (ctx.mounted) Navigator.pop(ctx);
                                if (mounted) {
                                  snack(context, res['message'] ?? 'Bukti pengeluaran berhasil disimpan!', color: C.green);
                                  _loadTripData(sel);
                                }
                              } else {
                                snack(context, res['message'] ?? 'Gagal menyimpan.', color: C.red);
                              }
                            } catch (e) {
                              snack(context, 'Gagal upload: $e', color: C.red);
                            } finally {
                              setMState(() => isSubmitting = false);
                            }
                          },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: C.primary,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                    ),
                    child: isSubmitting
                        ? const SpinKitThreeBounce(color: Colors.white, size: 20)
                        : Text('SIMPAN BUKTI PENGELUARAN', style: t(14.5, w: FontWeight.w800, c: Colors.white)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showExpenseListModal() {
    final sel = Tracker.I.selected;
    if (sel == null) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setMState) {
          final totalBensin = _tripExpenses.where((e) => e['kategori'] == 'bensin').fold<double>(0.0, (sum, e) => sum + ((e['nominal'] as num?)?.toDouble() ?? 0.0));
          final totalTol = _tripExpenses.where((e) => e['kategori'] == 'tol').fold<double>(0.0, (sum, e) => sum + ((e['nominal'] as num?)?.toDouble() ?? 0.0));
          final grandTotal = _tripExpenses.fold<double>(0.0, (sum, e) => sum + ((e['nominal'] as num?)?.toDouble() ?? 0.0));

          return SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 10),
                  Center(
                    child: Container(width: 44, height: 5, decoration: BoxDecoration(color: C.border, borderRadius: BorderRadius.circular(4))),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Bukti Pengeluaran Tercatat', style: t(17, w: FontWeight.w800)),
                              Text('${sel['nomor_surat_jalan']} • ${_tripExpenses.length} Struk', style: t(12, c: C.muted)),
                            ],
                          ),
                        ),
                        IconButton(
                          onPressed: () => Navigator.pop(ctx),
                          icon: const Icon(Icons.close_rounded, color: C.muted),
                        ),
                      ],
                    ),
                  ),
                  if (_tripExpenses.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(color: C.bg, borderRadius: BorderRadius.circular(16)),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceAround,
                          children: [
                            Column(
                              children: [
                                Text('⛽ Bensin', style: t(11, w: FontWeight.w700, c: C.accent)),
                                const SizedBox(height: 2),
                                Text('Rp ${totalBensin.toStringAsFixed(0)}', style: t(12.5, w: FontWeight.w800)),
                              ],
                            ),
                            Container(width: 1, height: 26, color: C.border),
                            Column(
                              children: [
                                Text('🛣️ Tol', style: t(11, w: FontWeight.w700, c: C.primary)),
                                const SizedBox(height: 2),
                                Text('Rp ${totalTol.toStringAsFixed(0)}', style: t(12.5, w: FontWeight.w800)),
                              ],
                            ),
                            Container(width: 1, height: 26, color: C.border),
                            Column(
                              children: [
                                Text('Total', style: t(11, w: FontWeight.w700, c: C.green)),
                                const SizedBox(height: 2),
                                Text('Rp ${grandTotal.toStringAsFixed(0)}', style: t(13, w: FontWeight.w800, c: C.green)),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  const Divider(color: C.border, height: 16),
                  Flexible(
                    child: _tripExpenses.isEmpty
                        ? Padding(
                            padding: const EdgeInsets.all(32),
                            child: Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.receipt_long_outlined, size: 48, color: C.muted),
                                  const SizedBox(height: 12),
                                  Text('Belum ada bukti bensin atau tol', style: t(14, w: FontWeight.w700)),
                                  const SizedBox(height: 4),
                                  Text('Tap tombol Catat Bensin / Tol untuk menambah', style: t(12, c: C.muted)),
                                ],
                              ),
                            ),
                          )
                        : ListView.separated(
                            padding: const EdgeInsets.fromLTRB(20, 6, 20, 20),
                            itemCount: _tripExpenses.length,
                            separatorBuilder: (_, __) => const SizedBox(height: 10),
                            itemBuilder: (_, i) {
                              final item = _tripExpenses[i];
                              final isBensin = item['kategori'] == 'bensin';
                              final photoUrl = item['file_url'] as String?;
                              final nom = (item['nominal'] as num?)?.toDouble() ?? 0.0;

                              return Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(color: C.border),
                                ),
                                child: Row(
                                  children: [
                                    // Thumbnail Foto
                                    if (photoUrl != null && photoUrl.isNotEmpty)
                                      InkWell(
                                        onTap: () {
                                          showDialog(
                                            context: context,
                                            builder: (_) => Dialog(
                                              backgroundColor: Colors.transparent,
                                              child: Stack(
                                                children: [
                                                  InteractiveViewer(
                                                    child: ClipRRect(
                                                      borderRadius: BorderRadius.circular(16),
                                                      child: Image.network(photoUrl, fit: BoxFit.contain),
                                                    ),
                                                  ),
                                                  Positioned(
                                                    top: 10,
                                                    right: 10,
                                                    child: IconButton(
                                                      icon: const Icon(Icons.close_rounded, color: Colors.white, size: 30),
                                                      onPressed: () => Navigator.pop(context),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          );
                                        },
                                        borderRadius: BorderRadius.circular(12),
                                        child: ClipRRect(
                                          borderRadius: BorderRadius.circular(12),
                                          child: Image.network(
                                            photoUrl,
                                            width: 54,
                                            height: 54,
                                            fit: BoxFit.cover,
                                            errorBuilder: (_, __, ___) => Container(
                                              width: 54,
                                              height: 54,
                                              color: C.bg,
                                              child: const Icon(Icons.broken_image_rounded, color: C.muted),
                                            ),
                                          ),
                                        ),
                                      )
                                    else
                                      Container(
                                        width: 54,
                                        height: 54,
                                        decoration: BoxDecoration(color: C.bg, borderRadius: BorderRadius.circular(12)),
                                        child: Icon(isBensin ? Icons.local_gas_station_rounded : Icons.toll_rounded, color: isBensin ? C.accent : C.primary),
                                      ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            children: [
                                              Container(
                                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                                decoration: BoxDecoration(
                                                  color: (isBensin ? C.accent : C.primary).withOpacity(0.12),
                                                  borderRadius: BorderRadius.circular(8),
                                                ),
                                                child: Text(
                                                  isBensin ? 'BBM / Bensin' : 'Tol',
                                                  style: t(10.5, w: FontWeight.w800, c: isBensin ? C.accent : C.primary),
                                                ),
                                              ),
                                              const Spacer(),
                                              Text(item['time'] ?? (item['tanggal'] ?? ''), style: t(11, c: C.muted)),
                                            ],
                                          ),
                                          const SizedBox(height: 4),
                                          Text('Rp ${nom.toStringAsFixed(0)}', style: t(15, w: FontWeight.w800)),
                                          if ((item['keterangan'] ?? '').toString().isNotEmpty)
                                            Text('${item['keterangan']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: t(12, c: C.muted)),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    // Tombol Hapus
                                    IconButton(
                                      icon: const Icon(Icons.delete_outline_rounded, color: C.red, size: 22),
                                      tooltip: 'Hapus Bukti',
                                      onPressed: () async {
                                        final ok = await _confirm('Hapus bukti ini?', 'Foto dan data pengeluaran ini akan dihapus permanen.', 'Hapus', C.red);
                                        if (!ok) return;
                                        try {
                                          final res = await Api.delete('/trucking/${sel['id']}/expense/${item['id']}');
                                          if (res['success'] == true) {
                                            setMState(() {
                                              _tripExpenses.removeWhere((e) => e['id'] == item['id']);
                                            });
                                            if (mounted) {
                                              setState(() {});
                                              snack(context, 'Bukti pengeluaran berhasil dihapus.', color: C.green);
                                            }
                                          } else {
                                            if (mounted) snack(context, res['message'] ?? 'Gagal menghapus.', color: C.red);
                                          }
                                        } catch (e) {
                                          if (mounted) snack(context, 'Gagal menghapus: $e', color: C.red);
                                        }
                                      },
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _openNav() async {
    final sel = Tracker.I.selected;
    if (sel == null) return;
    final dest = _dest != null
        ? '${_dest!.latitude},${_dest!.longitude}'
        : '${sel['consignee_name'] ?? ''} ${sel['consignee_address'] ?? ''}'.trim();
    final uri = Uri.parse('https://www.google.com/maps/dir/?api=1&destination=${Uri.encodeComponent(dest)}&travelmode=driving');
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      if (mounted) snack(context, 'Tidak bisa membuka Google Maps.', color: C.red);
    }
  }

  void _pickTrip() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.7),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const SizedBox(height: 10),
            Container(width: 44, height: 5, decoration: BoxDecoration(color: C.border, borderRadius: BorderRadius.circular(4))),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Row(children: [
                Expanded(child: Text('Pilih Surat Jalan', style: t(18, w: FontWeight.w800))),
                IconButton(
                  onPressed: () {
                    Navigator.pop(ctx);
                    _loadTrips();
                  },
                  icon: const Icon(Icons.refresh_rounded, color: C.muted),
                ),
              ]),
            ),
            Flexible(
              child: _trips.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(20),
                      child: EmptyState(icon: Icons.inbox_outlined, title: 'Tidak ada surat jalan aktif', text: 'Hubungi admin bila surat jalan belum muncul.'),
                    )
                  : ListView.separated(
                      shrinkWrap: true,
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                      itemCount: _trips.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (_, i) {
                        final item = _trips[i];
                        final selected = Tracker.I.selected?['id'] == item['id'];
                        return Material(
                          color: selected ? C.primary.withOpacity(0.06) : Colors.white,
                          borderRadius: BorderRadius.circular(16),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(16),
                            onTap: () {
                              Navigator.pop(ctx);
                              Tracker.I.select(item);
                            },
                            child: Container(
                              padding: const EdgeInsets.all(14),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(color: selected ? C.primary : C.border, width: selected ? 1.5 : 1),
                              ),
                              child: Row(children: [
                                Expanded(
                                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                    Text('${item['nomor_surat_jalan']}', style: t(14, w: FontWeight.w800)),
                                    const SizedBox(height: 2),
                                    Text('${item['consignee_name'] ?? '-'}', maxLines: 1, overflow: TextOverflow.ellipsis, style: t(12.5, c: C.muted)),
                                    Text('${fmtDate(item['tanggal'])}  •  ${item['nomor_polisi'] ?? '-'}', style: t(11, c: const Color(0xFF94A3B8))),
                                  ]),
                                ),
                                if (Tracker.I.isTracking(item)) const GpsPill(active: true) else StatusBadge(item['status']),
                              ]),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tracker = Tracker.I;
    final sel = tracker.selected;
    final trackingThis = tracker.isTracking(sel);
    final me = _me;
    final top = MediaQuery.of(context).padding.top;

    double? distKm = _routeKm;
    if (distKm == null && me != null && _dest != null) {
      distKm = Distance().distance(me, _dest!) / 1000;
    }
    final heading = (trackingThis && tracker.position != null) ? tracker.position!.heading : 0.0;

    return Scaffold(
      body: Stack(children: [
        FlutterMap(
          mapController: _map,
          options: MapOptions(
            initialCenter: me ?? const LatLng(-6.2, 106.8166),
            initialZoom: 12,
            onMapReady: () {
              _mapReady = true;
              _fitAll();
            },
            onPositionChanged: (camera, hasGesture) {
              if (hasGesture && _follow) setState(() => _follow = false);
            },
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.precision.trucking_mobile',
            ),
            PolylineLayer(polylines: [
              if (_route.length > 1)
                Polyline(points: _route, strokeWidth: 6, color: C.primary.withOpacity(0.75), borderStrokeWidth: 2, borderColor: Colors.white),
              for (final seg in _history) Polyline(points: seg, strokeWidth: 4, color: C.accent),
              if (trackingThis && tracker.trail.length > 1) Polyline(points: List<LatLng>.of(tracker.trail), strokeWidth: 5, color: C.green),
            ]),
            MarkerLayer(markers: [
              if (_dest != null)
                Marker(
                  point: _dest!,
                  width: 48,
                  height: 48,
                  alignment: Alignment.topCenter,
                  child: const Icon(Icons.location_on_rounded, color: C.red, size: 48),
                ),
              if (me != null)
                Marker(
                  point: me,
                  width: 56,
                  height: 56,
                  child: Container(
                    decoration: BoxDecoration(
                      color: trackingThis ? C.green : C.primary,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 3),
                      boxShadow: [BoxShadow(color: (trackingThis ? C.green : C.primary).withOpacity(0.45), blurRadius: 16, spreadRadius: 4)],
                    ),
                    child: Transform.rotate(
                      angle: heading * math.pi / 180,
                      child: const Icon(Icons.navigation_rounded, color: Colors.white, size: 28),
                    ),
                  ),
                ),
            ]),
          ],
        ),

        // ATAS: kartu surat jalan
        Positioned(
          top: top + 12,
          left: 16,
          right: 16,
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20), boxShadow: kShadow),
            child: _loadingTrips && sel == null
                ? const SizedBox(height: 44, child: Center(child: SpinKitThreeBounce(color: C.primary, size: 18)))
                : Row(children: [
                    Container(
                      padding: const EdgeInsets.all(9),
                      decoration: BoxDecoration(color: C.red.withOpacity(0.1), borderRadius: BorderRadius.circular(12)),
                      child: const Icon(Icons.place_rounded, color: C.red, size: 22),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: sel == null
                          ? Text('Belum ada surat jalan aktif', style: t(14, w: FontWeight.w800))
                          : Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                              Text('${sel['nomor_surat_jalan'] ?? '-'}', style: t(14, w: FontWeight.w800)),
                              Text('${sel['consignee_name'] ?? '-'}', maxLines: 1, overflow: TextOverflow.ellipsis, style: t(12, c: C.muted)),
                            ]),
                    ),
                    TextButton.icon(
                      onPressed: _pickTrip,
                      icon: const Icon(Icons.swap_horiz_rounded, size: 18),
                      label: Text('Ganti', style: t(13, w: FontWeight.w800, c: C.primary)),
                    ),
                  ]),
          ),
        ),

        // BAWAH: tombol peta + panel kontrol
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 16),
                child: Column(children: [
                  _mapButton(Icons.alt_route_rounded, 'Hitung ulang rute', () async {
                    await _computeRoute();
                    _fitAll();
                  }),
                  const SizedBox(height: 10),
                  _mapButton(Icons.zoom_out_map_rounded, 'Lihat semua', _fitAll),
                  const SizedBox(height: 10),
                  _mapButton(_follow ? Icons.gps_fixed_rounded : Icons.my_location_rounded, 'Posisi saya', _recenter, highlight: _follow),
                ]),
              ),
              const SizedBox(height: 14),
              _panel(sel, trackingThis, distKm),
            ],
          ),
        ),
      ]),
    );
  }

  Widget _mapButton(IconData icon, String tooltip, VoidCallback onTap, {bool highlight = false}) => Tooltip(
        message: tooltip,
        child: Material(
          color: highlight ? C.primary : Colors.white,
          shape: const CircleBorder(),
          elevation: 4,
          shadowColor: Colors.black26,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox(width: 50, height: 50, child: Icon(icon, color: highlight ? Colors.white : C.text, size: 22)),
          ),
        ),
      );

  Widget _metric(IconData icon, String value, String unit, String label, Color color) => Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
          decoration: BoxDecoration(color: C.bg, borderRadius: BorderRadius.circular(16)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(icon, color: color, size: 18),
            const SizedBox(height: 6),
            Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Flexible(child: Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: t(22, w: FontWeight.w800, h: 1))),
              const SizedBox(width: 3),
              Text(unit, style: t(11, w: FontWeight.w700, c: C.muted)),
            ]),
            const SizedBox(height: 4),
            Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: t(11, w: FontWeight.w600, c: C.muted)),
          ]),
        ),
      );

  Widget _panel(Map<String, dynamic>? sel, bool trackingThis, double? distKm) {
    final tracker = Tracker.I;
    String eta = '-';
    String etaUnit = 'mnt';
    if (_routeMin != null) {
      final m = _routeMin!.round();
      if (m >= 60) {
        eta = '${m ~/ 60}:${(m % 60).toString().padLeft(2, '0')}';
        etaUnit = 'jam';
      } else {
        eta = '$m';
      }
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        boxShadow: [BoxShadow(color: Color(0x220F172A), blurRadius: 24, offset: Offset(0, -6))],
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          GpsPill(active: trackingThis),
          const Spacer(),
          if (trackingThis) ...[
            Icon(tracker.failed > 0 ? Icons.sync_problem_rounded : Icons.cloud_done_rounded,
                size: 16, color: tracker.failed > 0 ? C.red : C.green),
            const SizedBox(width: 4),
            Text(tracker.failed > 0 ? 'Gagal kirim (${tracker.failed}x)' : 'Terkirim ${tracker.pings}x • ${tracker.lastSync}',
                style: t(11.5, w: FontWeight.w700, c: tracker.failed > 0 ? C.red : C.muted)),
          ] else
            Text(_dest == null ? 'Mencari lokasi tujuan...' : 'Tujuan ditemukan', style: t(11.5, w: FontWeight.w600, c: C.muted)),
        ]),
        const SizedBox(height: 14),
        Row(children: [
          _metric(Icons.speed_rounded, trackingThis ? tracker.speedKmh.toStringAsFixed(0) : '0', 'km/j', 'Kecepatan', C.primary),
          const SizedBox(width: 8),
          _metric(Icons.straighten_rounded, distKm != null ? distKm.toStringAsFixed(1) : '-', 'km', 'Jarak Tujuan', C.red),
          const SizedBox(width: 8),
          _metric(Icons.timer_outlined, eta, etaUnit, 'Estimasi', C.accent),
        ]),
        if (trackingThis && tracker.battery >= 0) ...[
          const SizedBox(height: 10),
          Row(children: [
            Icon(Icons.battery_charging_full_rounded, size: 16, color: tracker.battery < 20 ? C.red : C.green),
            const SizedBox(width: 4),
            Text('Baterai ${tracker.battery}%', style: t(12, w: FontWeight.w700, c: C.muted)),
            const Spacer(),
            if (tracker.position != null)
              Text('Akurasi ±${tracker.position!.accuracy.toStringAsFixed(0)} m', style: t(12, w: FontWeight.w700, c: C.muted)),
          ]),
        ],
        const SizedBox(height: 14),
        Row(children: [
          Expanded(
            child: SizedBox(
              height: 62,
              child: ElevatedButton(
                onPressed: (sel == null || _busy) ? null : _toggle,
                style: ElevatedButton.styleFrom(
                  backgroundColor: trackingThis ? C.red : C.green,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: C.border,
                  elevation: 0,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                ),
                child: _busy
                    ? const SpinKitThreeBounce(color: Colors.white, size: 20)
                    : Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                        Icon(trackingThis ? Icons.stop_rounded : Icons.play_arrow_rounded, size: 28),
                        const SizedBox(width: 6),
                        Text(trackingThis ? 'STOP GPS' : 'MULAI PERJALANAN',
                            style: t(16, w: FontWeight.w800, c: Colors.white, ls: 0.5)),
                      ]),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Tooltip(
            message: 'Navigasi Google Maps',
            child: SizedBox(
              width: 62,
              height: 62,
              child: ElevatedButton(
                onPressed: sel == null ? null : _openNav,
                style: ElevatedButton.styleFrom(
                  backgroundColor: C.accent,
                  foregroundColor: C.navy,
                  elevation: 0,
                  padding: EdgeInsets.zero,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                ),
                child: const Icon(Icons.directions_rounded, size: 30),
              ),
            ),
          ),
        ]),
        if (sel != null) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 50,
                  child: ElevatedButton.icon(
                    onPressed: _busy ? null : _addExpenseModal,
                    icon: const Icon(Icons.receipt_long_rounded, size: 20),
                    label: Text('CATAT BENSIN / TOL', style: t(12.5, w: FontWeight.w800, c: Colors.white, ls: 0.3)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: C.accent,
                      foregroundColor: C.navy,
                      elevation: 0,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              InkWell(
                onTap: _showExpenseListModal,
                borderRadius: BorderRadius.circular(16),
                child: Container(
                  height: 50,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: C.bg,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: _tripExpenses.isNotEmpty ? C.accent : C.border, width: 1.5),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.collections_rounded, size: 20, color: _tripExpenses.isNotEmpty ? C.accent : C.muted),
                      const SizedBox(width: 6),
                      Text(
                        '${_tripExpenses.length}',
                        style: t(14, w: FontWeight.w800, c: _tripExpenses.isNotEmpty ? C.accent : C.muted),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SizedBox(
                  height: 50,
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _finishTrip,
                    icon: const Icon(Icons.flag_circle_rounded, size: 20),
                    label: Text('SELESAI TRIP', style: t(12.5, w: FontWeight.w800, c: C.primary, ls: 0.3)),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: C.primary,
                      side: const BorderSide(color: C.primary, width: 2),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ]),
    );
  }
}

// ============================================================
// 3. RIWAYAT
// ============================================================
class HistoryPage extends StatefulWidget {
  final void Function(Map<String, dynamic>?) onOpenGps;
  const HistoryPage({super.key, required this.onOpenGps});

  @override
  State<HistoryPage> createState() => HistoryPageState();
}

class HistoryPageState extends State<HistoryPage> {
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;
  String _filter = 'all';

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    if (_items.isEmpty) setState(() => _loading = true);
    try {
      final d = await Api.get('/history');
      final list = ((d['truckings'] as List?) ?? []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
      if (mounted) {
        setState(() {
          _items = list;
          _loading = false;
        });
      }
    } on AuthExpired {
      if (mounted) logoutAndExit(context);
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    bool isDone(Map e) => e['finished_at'] != null && '${e['status']}'.toLowerCase() != 'rejected';
    final items = _filter == 'all'
        ? _items
        : _filter == 'done'
            ? _items.where(isDone).toList()
            : _items.where((e) => !isDone(e) && '${e['status']}'.toLowerCase() == _filter).toList();
    const filters = {'all': 'Semua', 'pending': 'Menunggu', 'approved': 'Disetujui', 'done': 'Selesai', 'rejected': 'Ditolak'};

    return Column(children: [
      PageHeader(title: 'Riwayat Surat Jalan', subtitle: '${_items.length} surat jalan terakhir'),
      SizedBox(
        height: 56,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          children: filters.entries.map((f) {
            final on = _filter == f.key;
            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(f.value, style: t(13, w: FontWeight.w700, c: on ? Colors.white : C.text)),
                selected: on,
                showCheckmark: false,
                selectedColor: C.navy,
                backgroundColor: Colors.white,
                side: BorderSide(color: on ? C.navy : C.border),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                onSelected: (_) => setState(() => _filter = f.key),
              ),
            );
          }).toList(),
        ),
      ),
      Expanded(
        child: RefreshIndicator(
          onRefresh: load,
          color: C.primary,
          child: _loading
              ? ListView(children: const [SizedBox(height: 120), Center(child: SpinKitThreeBounce(color: C.primary, size: 22))])
              : items.isEmpty
                  ? ListView(padding: const EdgeInsets.all(16), children: const [
                      EmptyState(icon: Icons.inbox_outlined, title: 'Tidak ada data', text: 'Belum ada surat jalan untuk filter ini.'),
                    ])
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                      itemCount: items.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemBuilder: (_, i) => _card(items[i]),
                    ),
        ),
      ),
    ]);
  }

  Widget _card(Map<String, dynamic> e) {
    final s = '${e['status']}'.toLowerCase();
    final canGps = s == 'approved' || s == 'pending';
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20), border: Border.all(color: C.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${e['nomor_surat_jalan'] ?? '-'}', style: t(15, w: FontWeight.w800)),
              const SizedBox(height: 2),
              Text(fmtDate(e['tanggal']), style: t(12, w: FontWeight.w600, c: C.muted)),
            ]),
          ),
          StatusBadge(e['status'], finishedAt: e['finished_at']),
        ]),
        const SizedBox(height: 12),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(Icons.place_rounded, size: 18, color: C.red),
          const SizedBox(width: 6),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${e['consignee_name'] ?? '-'}', style: t(13.5, w: FontWeight.w700)),
              if ((e['consignee_address'] ?? '').toString().isNotEmpty)
                Text('${e['consignee_address']}', maxLines: 2, overflow: TextOverflow.ellipsis, style: t(12, c: C.muted)),
            ]),
          ),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          const Icon(Icons.local_shipping_outlined, size: 16, color: C.muted),
          const SizedBox(width: 6),
          Text('${e['nomor_polisi'] ?? '-'}', style: t(12.5, w: FontWeight.w700, c: C.muted)),
          const SizedBox(width: 14),
          const Icon(Icons.inventory_2_outlined, size: 16, color: C.muted),
          const SizedBox(width: 6),
          Text('${e['qty'] ?? '-'}', style: t(12.5, w: FontWeight.w700, c: C.muted)),
          const Spacer(),
          if (canGps)
            TextButton.icon(
              onPressed: () => widget.onOpenGps(e),
              icon: const Icon(Icons.navigation_rounded, size: 18),
              label: Text('GPS', style: t(13, w: FontWeight.w800, c: C.primary)),
            ),
        ]),
      ]),
    );
  }
}

// ============================================================
// 4. AKUN
// ============================================================
class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  String _name = '-', _username = '-', _phone = '-', _email = '-';

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      if (!mounted) return;
      String v(String k) {
        final s = p.getString(k) ?? '';
        return s.isEmpty ? '-' : s;
      }

      setState(() {
        _name = v('user_name');
        _username = v('user_username');
        _phone = v('user_phone');
        _email = v('user_email');
      });
    });
  }

  Widget _row(IconData icon, String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(children: [
          Container(
            padding: const EdgeInsets.all(9),
            decoration: BoxDecoration(color: C.bg, borderRadius: BorderRadius.circular(12)),
            child: Icon(icon, size: 20, color: C.navy2),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: t(11.5, w: FontWeight.w600, c: C.muted)),
              Text(value, style: t(14, w: FontWeight.w700)),
            ]),
          ),
        ]),
      );

  Future<void> _logout() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: Text('Keluar akun?', style: t(18, w: FontWeight.w800)),
        content: Text('GPS yang aktif akan dimatikan.', style: t(14, c: C.muted)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('Batal', style: t(14, w: FontWeight.w700, c: C.muted))),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: C.red, foregroundColor: Colors.white, elevation: 0),
            child: Text('Keluar', style: t(14, w: FontWeight.w800, c: Colors.white)),
          ),
        ],
      ),
    );
    if (ok == true && mounted) await logoutAndExit(context);
  }

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.of(context).padding.top;
    return ListView(padding: EdgeInsets.zero, children: [
      Container(
        padding: EdgeInsets.fromLTRB(20, top + 28, 20, 30),
        decoration: const BoxDecoration(
          gradient: kHeaderGradient,
          borderRadius: BorderRadius.only(bottomLeft: Radius.circular(32), bottomRight: Radius.circular(32)),
        ),
        child: Column(children: [
          CircleAvatar(
            radius: 40,
            backgroundColor: C.accent,
            child: Text(_name != '-' ? _name[0].toUpperCase() : 'S', style: t(32, w: FontWeight.w800, c: C.navy)),
          ),
          const SizedBox(height: 12),
          Text(_name, style: t(20, w: FontWeight.w800, c: Colors.white)),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(color: Colors.white.withOpacity(0.12), borderRadius: BorderRadius.circular(20)),
            child: Text('Supir • @$_username', style: t(12, w: FontWeight.w700, c: Colors.white70)),
          ),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20), border: Border.all(color: C.border)),
            child: Column(children: [
              _row(Icons.phone_rounded, 'No. HP / WhatsApp', _phone),
              const Divider(color: C.border, height: 1),
              _row(Icons.alternate_email_rounded, 'Email', _email),
              const Divider(color: C.border, height: 1),
              _row(Icons.info_outline_rounded, 'Versi Aplikasi', '$kAppVersion (Build $kAppVersionCode)'),
              const Divider(color: C.border, height: 1),
              InkWell(
                onTap: () async {
                  snack(context, 'Memeriksa versi terbaru...');
                  try {
                    final res = await http.get(
                      Uri.parse('${Api.base}/app-version'),
                      headers: {'Accept': 'application/json'},
                    ).timeout(const Duration(seconds: 8));
                    if (res.statusCode == 200) {
                      final data = jsonDecode(res.body);
                      final serverCode = (data['version_code'] as num?)?.toInt() ?? 0;
                      if (serverCode > kAppVersionCode) {
                        final uri = Uri.parse(data['download_url'] ?? 'https://trucking.saleslog-pro.com/PrecisionDriver.apk');
                        await launchUrl(uri, mode: LaunchMode.externalApplication);
                      } else {
                        if (context.mounted) snack(context, 'Aplikasi sudah versi paling baru (v$kAppVersion).', color: C.green);
                      }
                    }
                  } catch (_) {
                    if (context.mounted) snack(context, 'Gagal terhubung ke server pembaruan.', color: C.red);
                  }
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(9),
                        decoration: BoxDecoration(color: C.primary.withOpacity(0.12), borderRadius: BorderRadius.circular(12)),
                        child: const Icon(Icons.sync_rounded, size: 20, color: C.primary),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Pembaruan Aplikasi', style: t(11.5, w: FontWeight.w600, c: C.muted)),
                            Text('Periksa Versi Terbaru', style: t(14, w: FontWeight.w700, c: C.primary)),
                          ],
                        ),
                      ),
                      const Icon(Icons.chevron_right_rounded, color: C.muted),
                    ],
                  ),
                ),
              ),
            ]),
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: C.accent.withOpacity(0.1),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: C.accent.withOpacity(0.3)),
            ),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.tips_and_updates_outlined, color: Color(0xFFB45309)),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Tips: Saat GPS aktif, jangan tutup aplikasi dari daftar aplikasi terbaru. '
                  'Matikan mode hemat baterai untuk aplikasi ini agar lokasi tetap terkirim.',
                  style: t(12.5, w: FontWeight.w600, c: const Color(0xFF92400E), h: 1.45),
                ),
              ),
            ]),
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            height: 56,
            child: OutlinedButton.icon(
              onPressed: _logout,
              style: OutlinedButton.styleFrom(
                foregroundColor: C.red,
                side: const BorderSide(color: C.red, width: 1.5),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
              ),
              icon: const Icon(Icons.logout_rounded),
              label: Text('KELUAR', style: t(15, w: FontWeight.w800, c: C.red, ls: 1)),
            ),
          ),
        ]),
      ),
    ]);
  }
}
