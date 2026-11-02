import 'dart:async';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_sign_in/google_sign_in.dart';

// File ini dibuat otomatis oleh GitHub Actions dari google-services.json
import 'firebase_config.dart';

const int minWithdraw = 1000;
final FirebaseFirestore db = FirebaseFirestore.instance;

typedef Snap = QuerySnapshot<Map<String, dynamic>>;
typedef Doc = QueryDocumentSnapshot<Map<String, dynamic>>;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: firebaseOptions);
  runApp(const JobKuApp());
}

const Color kPrimary = Color(0xFF4F46E5);
const Color kBg = Color(0xFFF4F5FB);
const Color kBorder = Color(0xFFE8EAF3);

/// Tema aplikasi: warna indigo, kartu bulat, tombol dan kolom isian modern.
ThemeData buildTheme() {
  final shape14 = RoundedRectangleBorder(borderRadius: BorderRadius.circular(14));
  OutlineInputBorder inputBorder(Color c, [double w = 1]) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: c, width: w),
      );
  return ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(seedColor: kPrimary),
    splashFactory: InkRipple.splashFactory,
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.android: CupertinoPageTransitionsBuilder(),
      TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
    }),
    scaffoldBackgroundColor: kBg,
    appBarTheme: const AppBarTheme(
      backgroundColor: kBg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: TextStyle(
        color: Color(0xFF1B2030),
        fontSize: 20,
        fontWeight: FontWeight.w800,
      ),
    ),
    cardTheme: CardTheme(
      color: Colors.white,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: kBorder),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 48),
        shape: shape14,
        textStyle: const TextStyle(fontWeight: FontWeight.w700),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 44),
        shape: shape14,
        side: const BorderSide(color: kBorder),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: inputBorder(const Color(0xFFE1E4F0)),
      enabledBorder: inputBorder(const Color(0xFFE1E4F0)),
      focusedBorder: inputBorder(kPrimary, 1.6),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      indicatorColor: kPrimary.withOpacity(0.12),
      labelTextStyle: MaterialStateProperty.all(
        const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
  );
}

class JobKuApp extends StatelessWidget {
  const JobKuApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'JobKu',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      builder: (context, child) => Stack(
        fit: StackFit.expand,
        textDirection: TextDirection.ltr,
        children: [
          child ?? const SizedBox.shrink(),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: ValueListenableBuilder<bool>(
              valueListenable: busyNotifier,
              builder: (_, busy, __) => IgnorePointer(
                child: AnimatedOpacity(
                  opacity: busy ? 1 : 0,
                  duration: const Duration(milliseconds: 150),
                  child: const LinearProgressIndicator(minHeight: 3),
                ),
              ),
            ),
          ),
        ],
      ),
      home: const AuthGate(),
    );
  }
}

/* ---------------- Helper ---------------- */

String rp(num n) {
  final s = n.toInt().toString();
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write('.');
    buf.write(s[i]);
  }
  return 'Rp $buf';
}

String fmt(dynamic t) {
  if (t is! Timestamp) return '';
  final d = t.toDate().toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(d.day)}/${two(d.month)}/${d.year} ${two(d.hour)}:${two(d.minute)}';
}

int tsOf(Map<String, dynamic> m) {
  final t = m['createdAt'];
  return t is Timestamp ? t.millisecondsSinceEpoch : 0x7fffffffffff;
}

List<Doc> sorted(Snap s) {
  final l = s.docs.toList();
  l.sort((a, b) => tsOf(b.data()).compareTo(tsOf(a.data())));
  return l;
}

bool isAdminEmail(User u) =>
    (u.email ?? '').toLowerCase() == adminEmail.toLowerCase();

/// Admin harus memakai email yang sudah terverifikasi (sama seperti di rules).
bool isAdminUser(User u) => isAdminEmail(u) && u.emailVerified;

/// Nama tampilan: username atau nama Google, atau bagian depan email.
String nameOf(User u) {
  final n = (u.displayName ?? '').trim();
  if (n.isNotEmpty) return n;
  return (u.email ?? '').split('@').first;
}

/// Data pendaftaran manual (username, telepon) yang disimpan ke profil
/// saat akun baru pertama kali dibuka.
Map<String, String>? pendingRegistration;

void toast(BuildContext c, String m) {
  ScaffoldMessenger.of(c)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(m)));
}

String errText(Object e) {
  if (e is TimeoutException) {
    return 'Koneksi lambat atau terputus. Coba lagi.';
  }
  if (e is FirebaseException) {
    if (e.code == 'permission-denied') {
      return 'Gagal: permission-denied. Pastikan Firestore Rules terbaru '
          'sudah dipublikasikan dan email sudah diverifikasi.';
    }
    return 'Gagal: ${e.code}';
  }
  return e.toString().replaceFirst('Exception: ', '');
}

/// Tampil sebagai bar progres tipis di atas layar selama ada proses berjalan.
final ValueNotifier<bool> busyNotifier = ValueNotifier<bool>(false);
bool _guardBusy = false;

/// Menjalankan sebuah aksi dengan penanganan error. Selama satu aksi masih
/// berjalan, tekanan tombol berikutnya diabaikan (mencegah tekan ganda), dan
/// ada batas waktu supaya aplikasi tidak menggantung saat koneksi buruk.
Future<void> guard(BuildContext c, Future<void> Function() f,
    [String? ok]) async {
  if (_guardBusy) return;
  _guardBusy = true;
  busyNotifier.value = true;
  try {
    await f().timeout(const Duration(seconds: 20));
    HapticFeedback.lightImpact();
    if (ok != null && c.mounted) toast(c, ok);
  } catch (e) {
    HapticFeedback.mediumImpact();
    if (c.mounted) toast(c, errText(e));
  } finally {
    _guardBusy = false;
    busyNotifier.value = false;
  }
}

Future<bool> confirm(BuildContext c, String msg) async {
  final r = await showDialog<bool>(
    context: c,
    builder: (ctx) => AlertDialog(
      content: Text(msg),
      actions: [
        PressScale(child: TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Batal'))),
        PressScale(child: FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Ya'))),
      ],
    ),
  );
  return r ?? false;
}

Widget statusChip(String s) {
  const labels = {
    'taken': 'Sedang dikerjakan',
    'submitted': 'Pending',
    'approved': 'Disetujui',
    'rejected': 'Ditolak',
    'pending': 'Menunggu',
  };
  const colors = {
    'taken': Colors.blue,
    'submitted': Colors.orange,
    'approved': Colors.green,
    'rejected': Colors.red,
    'pending': Colors.orange,
  };
  return pill(labels[s] ?? s, colors[s] ?? Colors.grey);
}

Widget pill(String text, Color c) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      color: c.withOpacity(0.12),
      borderRadius: BorderRadius.circular(99),
    ),
    child: Text(text,
        style: TextStyle(
            color: c, fontWeight: FontWeight.w600, fontSize: 12)),
  );
}

class Loading extends StatelessWidget {
  const Loading({super.key});
  @override
  Widget build(BuildContext context) =>
      const Center(child: CircularProgressIndicator());
}

class EmptyBox extends StatelessWidget {
  final String text;
  const EmptyBox(this.text, {super.key});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(40),
        child: Center(
          child: Text(text,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.grey)),
        ),
      );
}

class ErrorBox extends StatelessWidget {
  final Object error;
  const ErrorBox(this.error, {super.key});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(30),
        child: Center(
          child: Text(
            'Gagal memuat data (${error is FirebaseException ? (error as FirebaseException).code : error}).\n'
            'Pastikan Firestore Rules sudah dipublikasikan.',
            textAlign: TextAlign.center,
          ),
        ),
      );
}

/// Daftar dokumen dari sebuah stream, dengan [header] opsional di atasnya.
Widget docList(
  Stream<Snap> stream,
  String emptyText,
  Widget Function(Doc d) item, {
  List<Widget> header = const [],
  bool Function(Doc d)? filter,
}) {
  return StreamBuilder<Snap>(
    stream: stream,
    builder: (context, snap) {
      if (snap.hasError) return ErrorBox(snap.error!);
      if (!snap.hasData) return const Loading();
      final docs = sorted(snap.data!)
          .where((d) => filter == null || filter(d))
          .toList();
      return ListView(
        padding: const EdgeInsets.all(14),
        children: [
          ...header,
          if (docs.isEmpty) EmptyBox(emptyText),
          for (final d in docs) item(d),
        ],
      );
    },
  );
}

/* ---------------- Auth ---------------- */

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.userChanges(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Scaffold(body: Loading());
        }
        final u = snap.data;
        if (u == null) return const LoginPage();
        return HomePage(user: u, key: ValueKey(u.uid));
      },
    );
  }
}

String authError(Object e) {
  if (e is FirebaseAuthException) {
    switch (e.code) {
      case 'email-already-in-use':
        return 'Email sudah terdaftar. Silakan masuk.';
      case 'invalid-email':
        return 'Format email tidak valid';
      case 'weak-password':
        return 'Password minimal 6 karakter';
      case 'user-not-found':
      case 'wrong-password':
      case 'invalid-credential':
        return 'Email atau password salah';
      case 'user-disabled':
        return 'Akun ini dinonaktifkan';
      case 'too-many-requests':
        return 'Terlalu banyak percobaan, coba lagi nanti';
      case 'network-request-failed':
        return 'Tidak ada koneksi internet';
      case 'operation-not-allowed':
        return 'Login email/password belum diaktifkan di Firebase';
      default:
        return 'Gagal: ${e.code}';
    }
  }
  return errText(e);
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final usernameC = TextEditingController();
  final emailC = TextEditingController();
  final phoneC = TextEditingController();
  final passC = TextEditingController();
  bool register = false;
  bool showPass = false;
  bool busy = false;

  @override
  void dispose() {
    usernameC.dispose();
    emailC.dispose();
    phoneC.dispose();
    passC.dispose();
    super.dispose();
  }

  void _say(String m) {
    if (mounted) toast(context, m);
  }

  Future<void> _loginNative() async {
    final account = await GoogleSignIn(serverClientId: webClientId).signIn();
    if (account == null) return;
    final auth = await account.authentication;
    final cred = GoogleAuthProvider.credential(
      idToken: auth.idToken,
      accessToken: auth.accessToken,
    );
    await FirebaseAuth.instance.signInWithCredential(cred);
  }

  Future<void> _loginGoogle() async {
    setState(() => busy = true);
    try {
      await _loginNative();
    } catch (e) {
      final msg = e.toString();
      final devError =
          msg.contains('ApiException: 10') || msg.contains('sign_in_failed');
      if (devError) {
        // Cadangan: login lewat browser (tidak memakai klien OAuth Android)
        try {
          await FirebaseAuth.instance.signInWithProvider(GoogleAuthProvider());
        } catch (e2) {
          _say('Login Google gagal. Silakan daftar atau masuk dengan email.');
        }
      } else {
        _say('Login gagal: ${errText(e)}');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _loginPassword() async {
    final email = emailC.text.trim();
    final pass = passC.text;
    if (email.isEmpty || pass.isEmpty) {
      _say('Isi email dan password');
      return;
    }
    setState(() => busy = true);
    try {
      await FirebaseAuth.instance
          .signInWithEmailAndPassword(email: email, password: pass);
    } catch (e) {
      _say(authError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _register() async {
    final username = usernameC.text.trim();
    final email = emailC.text.trim();
    var digits = phoneC.text.replaceAll(RegExp(r'\D'), '');
    if (digits.startsWith('62')) digits = digits.substring(2);
    if (digits.startsWith('0')) digits = digits.substring(1);
    final phone = '+62$digits';
    final pass = passC.text;
    if (username.length < 3) {
      _say('Username minimal 3 karakter');
      return;
    }
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)) {
      _say('Format email tidak valid');
      return;
    }
    if (!RegExp(r'^\+628\d{7,12}$').hasMatch(phone)) {
      _say('Nomor telepon tidak valid (contoh +62 812 3456 7890)');
      return;
    }
    if (pass.length < 6) {
      _say('Password minimal 6 karakter');
      return;
    }
    setState(() => busy = true);
    try {
      pendingRegistration = {'username': username, 'phone': phone};
      final cred = await FirebaseAuth.instance
          .createUserWithEmailAndPassword(email: email, password: pass);
      await cred.user?.updateDisplayName(username);
      try {
        await cred.user?.sendEmailVerification();
        _say('Email verifikasi dikirim ke $email (cek juga folder spam).');
      } catch (_) {
        // bisa dikirim ulang dari layar verifikasi
      }
    } catch (e) {
      pendingRegistration = null;
      _say(authError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _forgot() async {
    final email = emailC.text.trim();
    if (email.isEmpty) {
      _say('Isi email dulu, lalu tekan Lupa password');
      return;
    }
    try {
      await FirebaseAuth.instance.sendPasswordResetEmail(email: email);
      _say('Link reset password dikirim ke email (cek juga folder spam).');
    } catch (e) {
      _say(authError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 84,
                      height: 84,
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                            colors: [Color(0xFF4F46E5), Color(0xFF7C3AED)]),
                        borderRadius: BorderRadius.circular(26),
                      ),
                      child: const Icon(Icons.work_rounded,
                          color: Colors.white, size: 42),
                    ),
                  ),
                  const SizedBox(height: 14),
                  const Text('JobKu',
                      textAlign: TextAlign.center,
                      style:
                          TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 6),
                  const Text(
                    'Kerjakan job, dapatkan saldo, tarik ke DANA.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey),
                  ),
                  const SizedBox(height: 22),
                  PressScale(child: OutlinedButton.icon(
                    onPressed: busy ? null : _loginGoogle,
                    icon: const Icon(Icons.g_mobiledata, size: 30),
                    label: const Text('Masuk dengan Google'),
                  )),
                  const SizedBox(height: 14),
                  const Row(children: [
                    Expanded(child: Divider()),
                    Padding(
                      padding: EdgeInsets.symmetric(horizontal: 10),
                      child: Text('atau', style: TextStyle(color: Colors.grey)),
                    ),
                    Expanded(child: Divider()),
                  ]),
                  const SizedBox(height: 14),
                  SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(value: false, label: Text('Masuk')),
                      ButtonSegment(value: true, label: Text('Daftar')),
                    ],
                    selected: {register},
                    onSelectionChanged: (s) =>
                        setState(() => register = s.first),
                  ),
                  const SizedBox(height: 14),
                  if (register) ...[
                    TextField(
                      controller: usernameC,
                      decoration: const InputDecoration(
                          labelText: 'Username',
                          prefixIcon: Icon(Icons.person_outline)),
                    ),
                    const SizedBox(height: 10),
                  ],
                  TextField(
                    controller: emailC,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(
                        labelText: 'Email',
                        prefixIcon: Icon(Icons.email_outlined)),
                  ),
                  const SizedBox(height: 10),
                  if (register) ...[
                    TextField(
                      controller: phoneC,
                      keyboardType: TextInputType.phone,
                      decoration: const InputDecoration(
                          labelText: 'Nomor telepon',
                          prefixText: '+62 ',
                          hintText: '8123456789',
                          prefixIcon: Icon(Icons.phone_outlined)),
                    ),
                    const SizedBox(height: 10),
                  ],
                  TextField(
                    controller: passC,
                    obscureText: !showPass,
                    decoration: InputDecoration(
                      labelText: 'Password',
                      prefixIcon: const Icon(Icons.lock_outline),
                      suffixIcon: PressScale(child: IconButton(
                        icon: Icon(showPass
                            ? Icons.visibility_off
                            : Icons.visibility),
                        onPressed: () => setState(() => showPass = !showPass),
                      )),
                    ),
                  ),
                  const SizedBox(height: 14),
                  PressScale(child: FilledButton(
                    onPressed:
                        busy ? null : (register ? _register : _loginPassword),
                    child: Text(busy
                        ? 'Memproses...'
                        : (register ? 'Daftar' : 'Masuk')),
                  )),
                  if (!register)
                    PressScale(child: TextButton(
                      onPressed: busy ? null : _forgot,
                      child: const Text('Lupa password?'),
                    )),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Akun email manual harus terverifikasi dulu (akun Google sudah otomatis).
class VerifyEmailPage extends StatefulWidget {
  final User user;
  final VoidCallback onChecked;
  final Future<void> Function() onLogout;
  const VerifyEmailPage({
    super.key,
    required this.user,
    required this.onChecked,
    required this.onLogout,
  });
  @override
  State<VerifyEmailPage> createState() => _VerifyEmailPageState();
}

class _VerifyEmailPageState extends State<VerifyEmailPage> {
  bool busy = false;

  void _say(String m) {
    if (mounted) toast(context, m);
  }

  Future<void> _send() async {
    setState(() => busy = true);
    try {
      await widget.user.sendEmailVerification();
      _say('Email verifikasi dikirim ke ${widget.user.email} (cek folder spam).');
    } catch (e) {
      _say(authError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _check() async {
    setState(() => busy = true);
    try {
      await FirebaseAuth.instance.currentUser?.reload();
      await FirebaseAuth.instance.currentUser?.getIdToken(true);
      final ok = FirebaseAuth.instance.currentUser?.emailVerified ?? false;
      if (ok) {
        widget.onChecked();
      } else {
        _say('Email belum terverifikasi. Buka link di email dulu.');
      }
    } catch (e) {
      _say(authError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Verifikasi email')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Icon(Icons.mark_email_unread_outlined, size: 64),
            const SizedBox(height: 16),
            Text(
              'Akun harus memakai email yang sudah diverifikasi.\n\n'
              'Kirim email verifikasi ke ${widget.user.email}, buka link di '
              'email itu, lalu tekan "Saya sudah verifikasi".',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            PressScale(child: FilledButton.icon(
              onPressed: busy ? null : _send,
              icon: const Icon(Icons.send),
              label: const Text('Kirim email verifikasi'),
            )),
            const SizedBox(height: 10),
            PressScale(child: OutlinedButton.icon(
              onPressed: busy ? null : _check,
              icon: const Icon(Icons.verified_outlined),
              label: const Text('Saya sudah verifikasi'),
            )),
            PressScale(child: TextButton(
              onPressed: busy ? null : widget.onLogout,
              child: const Text('Keluar'),
            )),
          ],
        ),
      ),
    );
  }
}

/* ---------------- Beranda ---------------- */

class HomePage extends StatefulWidget {
  final User user;
  const HomePage({super.key, required this.user});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int tab = 0;

  // Dibuat saat pertama dipakai, jadi langganan hanya dibuat sesuai peran.
  late final Stream<int> _userUnread = db
      .collection('tickets')
      .doc(widget.user.uid)
      .snapshots()
      .map((s) => s.data()?['unreadUser'] == true ? 1 : 0);
  late final Stream<int> _adminUnread = db
      .collection('tickets')
      .where('unreadAdmin', isEqualTo: true)
      .snapshots()
      .map((s) => s.docs.length);

  @override
  void initState() {
    super.initState();
    _ensureProfile();
  }

  Future<void> _ensureProfile() async {
    try {
      final ref = db.collection('users').doc(widget.user.uid);
      final snap = await ref.get();
      if (!snap.exists) {
        final reg = pendingRegistration;
        pendingRegistration = null;
        final providers = widget.user.providerData;
        await ref.set({
          'name': reg?['username'] ?? nameOf(widget.user),
          'email': widget.user.email ?? '',
          'photo': widget.user.photoURL ?? '',
          'phone': reg?['phone'] ?? '',
          'provider': providers.isNotEmpty ? providers.first.providerId : '',
          'balance': 0,
          'createdAt': FieldValue.serverTimestamp(),
        });
      }
    } catch (e) {
      if (mounted) toast(context, 'Gagal menyiapkan akun: ${errText(e)}');
    }
  }

  Future<void> _logout() async {
    try {
      await GoogleSignIn().signOut();
    } catch (_) {}
    await FirebaseAuth.instance.signOut();
  }

  @override
  Widget build(BuildContext context) {
    final u = FirebaseAuth.instance.currentUser ?? widget.user;
    if (!u.emailVerified) {
      return VerifyEmailPage(
        user: u,
        onChecked: () => setState(() {}),
        onLogout: _logout,
      );
    }
    final admin = isAdminUser(u);
    final pages = <Widget>[
      JobsTab(user: u),
      HistoryTab(user: u),
      if (!admin) ChatTab(user: u),
      if (admin) const AdminTab(),
    ];
    if (tab >= pages.length) tab = 0;
    return Scaffold(
      appBar: AppBar(
        title: const Text('💼 JobKu',
            style: TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          PressScale(child: IconButton(
            tooltip: 'Keluar',
            onPressed: _logout,
            icon: const Icon(Icons.logout),
          )),
        ],
      ),
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        switchInCurve: Curves.easeOut,
        layoutBuilder: (current, previous) => Stack(
          fit: StackFit.expand,
          children: [...previous, if (current != null) current],
        ),
        child: KeyedSubtree(key: ValueKey<int>(tab), child: pages[tab]),
      ),
      bottomNavigationBar: StreamBuilder<int>(
        stream: admin ? _adminUnread : _userUnread,
        builder: (context, snap) {
          final n = snap.data ?? 0;
          return NavigationBar(
            selectedIndex: tab,
            onDestinationSelected: (i) => setState(() => tab = i),
            destinations: [
              const NavigationDestination(
                  icon: Icon(Icons.work_outline),
                  selectedIcon: Icon(Icons.work),
                  label: 'Job'),
              const NavigationDestination(
                  icon: Icon(Icons.receipt_long_outlined),
                  selectedIcon: Icon(Icons.receipt_long),
                  label: 'Riwayat'),
              if (!admin)
                NavigationDestination(
                    icon: Badge(
                      isLabelVisible: n > 0,
                      smallSize: 9,
                      child: const Icon(Icons.support_agent_outlined),
                    ),
                    selectedIcon: const Icon(Icons.support_agent),
                    label: 'Chat Admin'),
              if (admin)
                NavigationDestination(
                    icon: Badge(
                      isLabelVisible: n > 0,
                      label: Text('$n'),
                      child: const Icon(Icons.admin_panel_settings_outlined),
                    ),
                    selectedIcon: const Icon(Icons.admin_panel_settings),
                    label: 'Admin'),
            ],
          );
        },
      ),
    );
  }
}

/* ---------------- Tab Job (user) ---------------- */

/// Ambil job. Satu job hanya bisa diambil satu user: job ditandai
/// `takenBy` dalam transaksi yang sama dengan pembuatan data pengerjaan.
Future<void> takeJob(BuildContext c, User u, Doc job) => guard(
    c,
    () => db.runTransaction((tx) async {
          final jRef = db.collection('jobs').doc(job.id);
          final sRef = db.collection('submissions').doc('${job.id}_${u.uid}');
          final j = await tx.get(jRef);
          final s = await tx.get(sRef);
          final cfg = await tx.get(db.collection('settings').doc('app'));
          if (cfg.data()?['jobsOpen'] == false) {
            throw Exception('Job sedang ditutup oleh admin');
          }
          final jd = j.data();
          if (jd == null || jd['active'] == false) {
            throw Exception('Job sudah tidak tersedia');
          }
          if (jd['takenBy'] != null) {
            throw Exception('Job ini sudah diambil user lain');
          }
          final sd = s.data();
          if (sd != null && sd['status'] != 'rejected') {
            throw Exception('Kamu sudah mengambil job ini');
          }
          tx.update(jRef, {
            'takenBy': u.uid,
            'takenByName': nameOf(u),
          });
          if (sd == null) {
            tx.set(sRef, {
              'jobId': job.id,
              'jobTitle': jd['title'],
              'reward': jd['reward'],
              'uid': u.uid,
              'userName': nameOf(u),
              'userEmail': u.email ?? '',
              'status': 'taken',
              'createdAt': FieldValue.serverTimestamp(),
            });
          } else {
            // sebelumnya ditolak, ambil lagi
            tx.update(sRef, {'status': 'taken'});
          }
        }),
    'Job diambil. Kerjakan lalu tekan Selesai.');

Future<void> finishJob(BuildContext c, String id) => guard(
    c,
    () => db.collection('submissions').doc(id).update({
          'status': 'submitted',
          'submittedAt': FieldValue.serverTimestamp(),
        }),
    'Terkirim. Status: Pending, menunggu review admin.');

class JobsTab extends StatelessWidget {
  final User user;
  const JobsTab({super.key, required this.user});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        BalanceCard(user: user),
        Expanded(child: _body()),
      ],
    );
  }

  Widget _body() {
    return StreamBuilder<Snap>(
      stream: db
          .collection('submissions')
          .where('uid', isEqualTo: user.uid)
          .snapshots(),
      builder: (context, subSnap) {
        return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          stream: db.collection('settings').doc('app').snapshots(),
          builder: (context, cfgSnap) {
            if (subSnap.hasError) return ErrorBox(subSnap.error!);
            if (!subSnap.hasData) return const Loading();
            final open = cfgSnap.data?.data()?['jobsOpen'] != false;
            final subs = subSnap.data!.docs;
            Doc? current;
            for (final s in subs) {
              if (s.data()['status'] == 'taken') {
                current = s;
                break;
              }
            }
            if (current != null) return CurrentJobView(sub: current);
            final pending =
                subs.where((s) => s.data()['status'] == 'submitted').length;
            return JobFinder(user: user, open: open, pending: pending);
          },
        );
      },
    );
  }
}

/// Saldo di bagian atas tab Job, dengan tombol sendiri untuk menarik saldo.
class BalanceCard extends StatelessWidget {
  final User user;
  const BalanceCard({super.key, required this.user});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: db.collection('users').doc(user.uid).snapshots(),
      builder: (context, snap) {
        final bal = ((snap.data?.data()?['balance'] ?? 0) as num).toInt();
        return Container(
          width: double.infinity,
          margin: const EdgeInsets.fromLTRB(14, 14, 14, 0),
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
                colors: [kPrimary, Color(0xFF7C3AED)]),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Saldo kamu',
                        style: TextStyle(color: Colors.white70)),
                    const SizedBox(height: 4),
                    Text(rp(bal),
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 28,
                            fontWeight: FontWeight.w800)),
                  ],
                ),
              ),
              PressScale(child: FilledButton.tonalIcon(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => WithdrawPage(user: user)),
                ),
                icon: const Icon(Icons.account_balance_wallet),
                label: const Text('Tarik Saldo'),
              )),
            ],
          ),
        );
      },
    );
  }
}

/// Halaman penarikan ke DANA (dibuka dari tombol Tarik Saldo).
class WithdrawPage extends StatelessWidget {
  final User user;
  const WithdrawPage({super.key, required this.user});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Tarik Saldo')),
      body: WalletTab(user: user),
    );
  }
}

class JobCard extends StatelessWidget {
  final String title;
  final String description;
  final num reward;
  final Widget footer;
  const JobCard({
    super.key,
    required this.title,
    required this.description,
    required this.reward,
    required this.footer,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            if (description.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(description,
                  style: const TextStyle(color: Colors.black54, fontSize: 15)),
            ],
            const SizedBox(height: 12),
            Text('Hadiah ${rp(reward)}',
                style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    color: Colors.green,
                    fontSize: 16)),
            const SizedBox(height: 14),
            footer,
          ],
        ),
      ),
    );
  }
}

/// Job yang sedang dikerjakan user: tombol "Sudah Selesai" langsung
/// mengubah status menjadi Pending untuk direview admin.
class CurrentJobView extends StatelessWidget {
  final Doc sub;
  const CurrentJobView({super.key, required this.sub});

  @override
  Widget build(BuildContext context) {
    final sd = sub.data();
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: db.collection('jobs').doc('${sd['jobId']}').snapshots(),
      builder: (context, js) {
        final desc = '${js.data?.data()?['description'] ?? ''}';
        return ListView(
          padding: const EdgeInsets.all(14),
          children: [
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text('Job kamu saat ini',
                  style: TextStyle(color: Colors.grey)),
            ),
            JobCard(
              title: '${sd['jobTitle'] ?? ''}',
              description: desc,
              reward: (sd['reward'] ?? 0) as num,
              footer: SizedBox(
                width: double.infinity,
                child: PressScale(child: FilledButton.icon(
                  style: FilledButton.styleFrom(backgroundColor: Colors.green),
                  onPressed: () => finishJob(context, sub.id),
                  icon: const Icon(Icons.check_circle),
                  label: const Text('Sudah Selesai'),
                )),
              ),
            ),
          ],
        );
      },
    );
  }
}

enum FinderPhase { idle, searching, found, none }

/// Layar pencarian job: user tidak melihat daftar job, hanya satu job
/// yang "dikocok" secara acak dari job yang masih tersedia.
class JobFinder extends StatefulWidget {
  final User user;
  final bool open;
  final int pending;
  const JobFinder({
    super.key,
    required this.user,
    required this.open,
    required this.pending,
  });

  @override
  State<JobFinder> createState() => _JobFinderState();
}

class _JobFinderState extends State<JobFinder>
    with SingleTickerProviderStateMixin {
  static const icons = ['🎲', '🃏', '📦', '🎁', '💼', '🔍'];
  late final AnimationController shake;
  Timer? iconTimer;
  int iconIdx = 0;
  FinderPhase phase = FinderPhase.idle;
  Doc? candidate;
  String notice = '';
  bool busy = false;

  @override
  void initState() {
    super.initState();
    shake = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 450));
  }

  @override
  void dispose() {
    iconTimer?.cancel();
    shake.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    setState(() {
      phase = FinderPhase.searching;
      candidate = null;
      notice = '';
    });
    shake.repeat();
    iconTimer = Timer.periodic(const Duration(milliseconds: 140), (_) {
      if (mounted) setState(() => iconIdx = (iconIdx + 1) % icons.length);
    });
    final wait = Future<void>.delayed(
        Duration(milliseconds: 2200 + Random().nextInt(1800)));
    Doc? pick;
    var msg = '';
    try {
      final cfg = await db.collection('settings').doc('app').get();
      if (cfg.data()?['jobsOpen'] == false) {
        msg = 'Job sedang ditutup oleh admin. Coba lagi nanti.';
      } else {
        final snap = await db.collection('jobs').get();
        final free = snap.docs.where((j) {
          final d = j.data();
          return d['active'] != false && d['takenBy'] == null;
        }).toList();
        if (free.isEmpty) {
          msg = 'Belum ada job yang tersedia saat ini. Coba lagi nanti.';
        } else {
          pick = free[Random().nextInt(free.length)];
        }
      }
    } catch (e) {
      msg = errText(e);
    }
    await wait;
    iconTimer?.cancel();
    shake.stop();
    if (!mounted) return;
    setState(() {
      candidate = pick;
      notice = msg;
      phase = pick != null ? FinderPhase.found : FinderPhase.none;
    });
  }

  Future<void> _take() async {
    final c = candidate;
    if (c == null || busy) return;
    setState(() => busy = true);
    await takeJob(context, widget.user, c);
    if (!mounted) return;
    setState(() {
      busy = false;
      phase = FinderPhase.idle;
      candidate = null;
    });
  }

  Widget _idle() {
    return Column(
      children: [
        const SizedBox(height: 40),
        const Text('🎲', style: TextStyle(fontSize: 72)),
        const SizedBox(height: 12),
        const Text('Siap mengerjakan job?',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
        const SizedBox(height: 6),
        Text(
          widget.open
              ? 'Tekan tombol di bawah untuk mencari job yang tersedia.'
              : 'Job sedang ditutup oleh admin. Coba lagi nanti.',
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.black54),
        ),
        const SizedBox(height: 24),
        PressScale(child: FilledButton.icon(
          onPressed: widget.open ? _search : null,
          icon: const Icon(Icons.search),
          label: const Text('Cari Job'),
        )),
        if (widget.pending > 0) ...[
          const SizedBox(height: 20),
          pill('Pending review admin: ${widget.pending}', Colors.orange),
        ],
      ],
    );
  }

  Widget _searching() {
    return Column(
      children: [
        const SizedBox(height: 40),
        AnimatedBuilder(
          animation: shake,
          builder: (context, child) => Transform.rotate(
            angle: sin(shake.value * 2 * pi) * 0.35,
            child: child,
          ),
          child: Text(icons[iconIdx], style: const TextStyle(fontSize: 80)),
        ),
        const SizedBox(height: 20),
        const Text('Sedang mencari job yang tersedia...',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        const SizedBox(height: 16),
        const SizedBox(width: 200, child: LinearProgressIndicator()),
      ],
    );
  }

  Widget _found() {
    final d = candidate!.data();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(bottom: 8),
          child: Text('🎉 Job ditemukan!',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        ),
        JobCard(
          title: '${d['title'] ?? ''}',
          description: '${d['description'] ?? ''}',
          reward: (d['reward'] ?? 0) as num,
          footer: Row(
            children: [
              Expanded(
                child: PressScale(child: FilledButton(
                  onPressed: busy ? null : _take,
                  child: Text(busy ? 'Memproses...' : 'Ambil Job'),
                )),
              ),
              const SizedBox(width: 10),
              PressScale(child: TextButton(
                onPressed: busy
                    ? null
                    : () => setState(() {
                          phase = FinderPhase.idle;
                          candidate = null;
                        }),
                child: const Text('Batal'),
              )),
            ],
          ),
        ),
      ],
    );
  }

  Widget _none() {
    return Column(
      children: [
        const SizedBox(height: 40),
        const Text('😴', style: TextStyle(fontSize: 64)),
        const SizedBox(height: 12),
        Text(notice,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.black54, fontSize: 15)),
        const SizedBox(height: 20),
        PressScale(child: FilledButton.icon(
          onPressed: _search,
          icon: const Icon(Icons.refresh),
          label: const Text('Cari Lagi'),
        )),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final Widget body;
    switch (phase) {
      case FinderPhase.idle:
        body = _idle();
      case FinderPhase.searching:
        body = _searching();
      case FinderPhase.found:
        body = _found();
      case FinderPhase.none:
        body = _none();
    }
    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          switchInCurve: Curves.easeOut,
          child: KeyedSubtree(key: ValueKey<FinderPhase>(phase), child: body),
        ),
      ],
    );
  }
}

/* ---------------- Tab Riwayat (user) ---------------- */

class HistoryTab extends StatelessWidget {
  final User user;
  const HistoryTab({super.key, required this.user});

  @override
  Widget build(BuildContext context) {
    return docList(
      db.collection('submissions').where('uid', isEqualTo: user.uid).snapshots(),
      'Kamu belum mengambil job.',
      (s) {
        final d = s.data();
        return Card(
          margin: const EdgeInsets.only(bottom: 12),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text('${d['jobTitle'] ?? ''}',
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w700)),
                    ),
                    statusChip('${d['status']}'),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                    '${rp((d['reward'] ?? 0) as num)}  •  ${fmt(d['createdAt'])}',
                    style: const TextStyle(color: Colors.black54)),
              ],
            ),
          ),
        );
      },
    );
  }
}

/* ---------------- Tab Saldo (user) ---------------- */

class WalletTab extends StatefulWidget {
  final User user;
  const WalletTab({super.key, required this.user});
  @override
  State<WalletTab> createState() => _WalletTabState();
}

class _WalletTabState extends State<WalletTab> {
  final danaC = TextEditingController();
  final amtC = TextEditingController();
  bool busy = false;

  @override
  void dispose() {
    danaC.dispose();
    amtC.dispose();
    super.dispose();
  }

  Future<void> _request() async {
    setState(() => busy = true);
    await guard(context, () async {
      final dana = danaC.text.replaceAll(RegExp(r'\D'), '');
      final amt = int.tryParse(amtC.text.replaceAll(RegExp(r'\D'), '')) ?? 0;
      if (dana.length < 9 || dana.length > 15) {
        throw Exception('Nomor DANA tidak valid');
      }
      if (amt < minWithdraw) {
        throw Exception('Minimum penarikan ${rp(minWithdraw)}');
      }
      final u = await db.collection('users').doc(widget.user.uid).get();
      final bal = ((u.data()?['balance'] ?? 0) as num).toInt();
      if (amt > bal) throw Exception('Saldo tidak cukup');
      final pend = await db
          .collection('withdrawals')
          .where('uid', isEqualTo: widget.user.uid)
          .where('status', isEqualTo: 'pending')
          .limit(1)
          .get();
      if (pend.docs.isNotEmpty) {
        throw Exception('Masih ada permintaan yang menunggu');
      }
      await db.collection('withdrawals').add({
        'uid': widget.user.uid,
        'userName': nameOf(widget.user),
        'userEmail': widget.user.email ?? '',
        'amount': amt,
        'danaNumber': dana,
        'status': 'pending',
        'createdAt': FieldValue.serverTimestamp(),
      });
      danaC.clear();
      amtC.clear();
    }, 'Permintaan penarikan dikirim.');
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: db.collection('users').doc(widget.user.uid).snapshots(),
      builder: (context, us) {
        final bal = ((us.data?.data()?['balance'] ?? 0) as num).toInt();
        final header = <Widget>[
          Container(
            padding: const EdgeInsets.all(18),
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                  colors: [kPrimary, Color(0xFF7C3AED)]),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Saldo kamu',
                    style: TextStyle(color: Colors.white70)),
                const SizedBox(height: 4),
                Text(rp(bal),
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 30,
                        fontWeight: FontWeight.w800)),
              ],
            ),
          ),
          Card(
            margin: const EdgeInsets.only(bottom: 16),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Tarik ke DANA',
                      style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Text(
                      'Minimum penarikan ${rp(minWithdraw)}. Saldo berkurang setelah admin menyetujui.',
                      style: const TextStyle(color: Colors.black54)),
                  const SizedBox(height: 12),
                  TextField(
                    controller: danaC,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(
                        labelText: 'Nomor DANA',
                        hintText: '08xxxxxxxxxx'),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: amtC,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                        labelText: 'Jumlah penarikan',
                        hintText: '$minWithdraw'),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: PressScale(child: FilledButton(
                      onPressed: busy ? null : _request,
                      child: Text(busy ? 'Mengirim...' : 'Ajukan Penarikan'),
                    )),
                  ),
                ],
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text('Riwayat penarikan',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          ),
        ];
        return docList(
          db
              .collection('withdrawals')
              .where('uid', isEqualTo: widget.user.uid)
              .snapshots(),
          'Belum ada penarikan.',
          (w) {
            final d = w.data();
            return Card(
              margin: const EdgeInsets.only(bottom: 10),
              child: ListTile(
                title: Text(rp((d['amount'] ?? 0) as num),
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle:
                    Text('DANA ${d['danaNumber']}  •  ${fmt(d['createdAt'])}'),
                trailing: statusChip('${d['status']}'),
              ),
            );
          },
          header: header,
        );
      },
    );
  }
}

/* ---------------- Admin ---------------- */

Future<void> approveSub(BuildContext c, String id) => guard(
    c,
    () => db.runTransaction((tx) async {
          final sRef = db.collection('submissions').doc(id);
          final s = await tx.get(sRef);
          final sd = s.data();
          if (sd == null || sd['status'] != 'submitted') {
            throw Exception('Status sudah berubah');
          }
          final uRef = db.collection('users').doc('${sd['uid']}');
          final u = await tx.get(uRef);
          final ud = u.data();
          if (ud == null) throw Exception('User tidak ditemukan');
          final bal = ((ud['balance'] ?? 0) as num).toInt();
          final reward = ((sd['reward'] ?? 0) as num).toInt();
          tx.update(sRef, {
            'status': 'approved',
            'reviewedAt': FieldValue.serverTimestamp(),
          });
          tx.update(uRef, {'balance': bal + reward});
        }),
    'Diterima, saldo user bertambah.');

/// Tolak hasil kerja. Job tetap tertutup (tidak kembali ke daftar job).
Future<void> rejectSub(BuildContext c, String id) => guard(
    c,
    () => db.collection('submissions').doc(id).update({
          'status': 'rejected',
          'reviewedAt': FieldValue.serverTimestamp(),
        }),
    'Ditolak.');

/// Admin melepas job dari user yang mengambilnya (mis. tidak dikerjakan).
Future<void> releaseJob(BuildContext c, Doc job) async {
  final yes = await confirm(c,
      'Lepas job ini dari user yang mengambilnya? Job akan tersedia lagi.');
  if (!yes || !c.mounted) return;
  await guard(
      c,
      () => db.runTransaction((tx) async {
            final jRef = db.collection('jobs').doc(job.id);
            final j = await tx.get(jRef);
            final taker = j.data()?['takenBy'];
            if (taker == null) {
              throw Exception('Job ini sedang tidak diambil siapa pun');
            }
            final sRef = db.collection('submissions').doc('${job.id}_$taker');
            final s = await tx.get(sRef);
            if (s.data()?['status'] == 'approved') {
              throw Exception('Job ini sudah disetujui, tidak bisa dilepas');
            }
            if (s.exists) {
              tx.update(sRef, {
                'status': 'rejected',
                'reviewedAt': FieldValue.serverTimestamp(),
              });
            }
            tx.update(jRef, {'takenBy': null, 'takenByName': null});
          }),
      'Job dilepas dan tersedia lagi.');
}

Future<void> approveWd(BuildContext c, String id) async {
  final yes = await confirm(
      c, 'Sudah transfer ke DANA user? Saldo user akan dikurangi.');
  if (!yes || !c.mounted) return;
  await guard(
      c,
      () => db.runTransaction((tx) async {
            final wRef = db.collection('withdrawals').doc(id);
            final w = await tx.get(wRef);
            final wd = w.data();
            if (wd == null || wd['status'] != 'pending') {
              throw Exception('Status sudah berubah');
            }
            final uRef = db.collection('users').doc('${wd['uid']}');
            final u = await tx.get(uRef);
            final bal = ((u.data()?['balance'] ?? 0) as num).toInt();
            final amt = ((wd['amount'] ?? 0) as num).toInt();
            if (bal < amt) {
              throw Exception('Saldo user tidak cukup, sebaiknya tolak');
            }
            tx.update(wRef, {
              'status': 'approved',
              'reviewedAt': FieldValue.serverTimestamp(),
            });
            tx.update(uRef, {'balance': bal - amt});
          }),
      'Penarikan disetujui, saldo dikurangi.');
}

Future<void> rejectWd(BuildContext c, String id) => guard(
    c,
    () => db.collection('withdrawals').doc(id).update({
          'status': 'rejected',
          'reviewedAt': FieldValue.serverTimestamp(),
        }),
    'Ditolak, saldo user tetap utuh.');

class AdminTab extends StatelessWidget {
  const AdminTab({super.key});

  @override
  Widget build(BuildContext context) {
    return const DefaultTabController(
      length: 5,
      child: Column(
        children: [
          TabBar(isScrollable: true, tabs: [
            Tab(text: 'Kelola Job'),
            Tab(text: 'Review'),
            Tab(text: 'Penarikan'),
            Tab(text: 'Chat'),
            Tab(text: 'Saldo User'),
          ]),
          Expanded(
            child: TabBarView(children: [
              AdminJobs(),
              AdminReview(),
              AdminWithdrawals(),
              AdminChats(),
              AdminUsers(),
            ]),
          ),
        ],
      ),
    );
  }
}

class AdminJobs extends StatefulWidget {
  const AdminJobs({super.key});
  @override
  State<AdminJobs> createState() => _AdminJobsState();
}

class _AdminJobsState extends State<AdminJobs> {
  String filterKey = 'all';

  bool _filter(Doc j) {
    final d = j.data();
    final taken = d['takenBy'] != null;
    final active = d['active'] != false;
    switch (filterKey) {
      case 'free':
        return !taken && active;
      case 'taken':
        return taken;
      case 'closed':
        return !active;
      default:
        return true;
    }
  }

  final titleC = TextEditingController();
  final descC = TextEditingController();
  final rewardC = TextEditingController();

  @override
  void dispose() {
    titleC.dispose();
    descC.dispose();
    rewardC.dispose();
    super.dispose();
  }

  Future<void> _add() => guard(context, () async {
        final title = titleC.text.trim();
        final desc = descC.text.trim();
        final reward =
            int.tryParse(rewardC.text.replaceAll(RegExp(r'\D'), '')) ?? 0;
        if (title.isEmpty || desc.isEmpty || reward <= 0) {
          throw Exception('Lengkapi nama, deskripsi, dan hadiah');
        }
        await db.collection('jobs').add({
          'title': title,
          'description': desc,
          'reward': reward,
          'active': true,
          'takenBy': null,
          'createdAt': FieldValue.serverTimestamp(),
        });
        titleC.clear();
        descC.clear();
        rewardC.clear();
      }, 'Job ditambahkan.');

  @override
  Widget build(BuildContext context) {
    final header = <Widget>[
      const JobsSwitch(),
      Card(
        margin: const EdgeInsets.only(bottom: 14),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Buat job baru',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              const SizedBox(height: 10),
              TextField(
                controller: titleC,
                decoration: const InputDecoration(
                    labelText: 'Nama job'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: descC,
                minLines: 3,
                maxLines: 6,
                decoration: const InputDecoration(
                    labelText: 'Deskripsi'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: rewardC,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                    labelText: 'Hadiah (Rp)',
                    hintText: '1000'),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: PressScale(child: FilledButton(
                    onPressed: _add, child: const Text('Tambah Job'))),
              ),
            ],
          ),
        ),
      ),
      Wrap(
        spacing: 8,
        children: [
          for (final f in const [
            ['all', 'Semua'],
            ['free', 'Tersedia'],
            ['taken', 'Diambil'],
            ['closed', 'Ditutup'],
          ])
            ChoiceChip(
              label: Text(f[1]),
              selected: filterKey == f[0],
              onSelected: (_) => setState(() => filterKey = f[0]),
            ),
        ],
      ),
      const SizedBox(height: 12),
    ];
    return docList(
      db.collection('jobs').snapshots(),
      'Belum ada job.',
      (j) {
        final d = j.data();
        final active = d['active'] != false;
        return Card(
          margin: const EdgeInsets.only(bottom: 12),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text('${d['title'] ?? ''}',
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w700)),
                    ),
                    d['takenBy'] != null
                        ? pill('Diambil', Colors.orange)
                        : (active
                            ? pill('Tersedia', Colors.green)
                            : pill('Ditutup', Colors.red)),
                  ],
                ),
                const SizedBox(height: 4),
                Text('${d['description'] ?? ''}',
                    style: const TextStyle(color: Colors.black54)),
                const SizedBox(height: 6),
                Text(rp((d['reward'] ?? 0) as num),
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, color: Colors.green)),
                if (d['takenBy'] != null) ...[
                  const SizedBox(height: 4),
                  Text('Diambil oleh: ${d['takenByName'] ?? ''}',
                      style: const TextStyle(color: Colors.orange)),
                ],
                const SizedBox(height: 6),
                Wrap(spacing: 8, children: [
                  if (d['takenBy'] != null)
                    PressScale(child: OutlinedButton(
                      onPressed: () => releaseJob(context, j),
                      child: const Text('Lepas Job'),
                    )),
                  PressScale(child: OutlinedButton(
                    onPressed: () => guard(
                        context,
                        () => db
                            .collection('jobs')
                            .doc(j.id)
                            .update({'active': !active})),
                    child: Text(active ? 'Tutup Job' : 'Buka Job'),
                  )),
                  PressScale(child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.red),
                    onPressed: () async {
                      final yes = await confirm(context, 'Hapus job ini?');
                      if (!yes || !context.mounted) return;
                      await guard(
                          context,
                          () => db.collection('jobs').doc(j.id).delete(),
                          'Job dihapus.');
                    },
                    child: const Text('Hapus'),
                  )),
                ]),
              ],
            ),
          ),
        );
      },
      header: header,
      filter: _filter,
    );
  }
}

class AdminReview extends StatelessWidget {
  const AdminReview({super.key});

  @override
  Widget build(BuildContext context) {
    return docList(
      db
          .collection('submissions')
          .where('status', isEqualTo: 'submitted')
          .snapshots(),
      'Tidak ada job yang menunggu review.',
      (s) {
        final d = s.data();
        return Card(
          margin: const EdgeInsets.only(bottom: 12),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${d['jobTitle'] ?? ''}',
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text('${d['userName'] ?? ''}  •  ${d['userEmail'] ?? ''}',
                    style: const TextStyle(color: Colors.black54)),
                Text('Dikirim ${fmt(d['submittedAt'])}',
                    style: const TextStyle(color: Colors.black54)),
                const SizedBox(height: 8),
                JobDescription(jobId: '${d['jobId'] ?? ''}'),
                const SizedBox(height: 6),
                Text(rp((d['reward'] ?? 0) as num),
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, color: Colors.green)),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(
                    child: PressScale(child: FilledButton(
                      style: FilledButton.styleFrom(
                          backgroundColor: Colors.green),
                      onPressed: () => approveSub(context, s.id),
                      child: const Text('Terima'),
                    )),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: PressScale(child: FilledButton(
                      style: FilledButton.styleFrom(
                          backgroundColor: Colors.red),
                      onPressed: () => rejectSub(context, s.id),
                      child: const Text('Tolak'),
                    )),
                  ),
                ]),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Deskripsi lengkap sebuah job (dibaca dari data job), supaya admin
/// langsung tahu tugas apa yang dinilai.
class JobDescription extends StatelessWidget {
  final String jobId;
  const JobDescription({super.key, required this.jobId});

  @override
  Widget build(BuildContext context) {
    if (jobId.isEmpty) return const SizedBox.shrink();
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: db.collection('jobs').doc(jobId).snapshots(),
      builder: (context, snap) {
        String text;
        if (snap.hasError) {
          text = 'Deskripsi gagal dimuat.';
        } else if (!snap.hasData) {
          text = 'Memuat deskripsi...';
        } else if (!snap.data!.exists) {
          text = 'Deskripsi tidak tersedia (job sudah dihapus).';
        } else {
          final d = '${snap.data!.data()?['description'] ?? ''}'.trim();
          text = d.isEmpty ? 'Job ini tidak punya deskripsi.' : d;
        }
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.blue.withOpacity(0.07),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Tugas yang harus dikerjakan:',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              SelectableText(text),
            ],
          ),
        );
      },
    );
  }
}

class AdminWithdrawals extends StatelessWidget {
  const AdminWithdrawals({super.key});

  @override
  Widget build(BuildContext context) {
    return docList(
      db
          .collection('withdrawals')
          .where('status', isEqualTo: 'pending')
          .snapshots(),
      'Tidak ada permintaan penarikan.',
      (w) {
        final d = w.data();
        return Card(
          margin: const EdgeInsets.only(bottom: 12),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(rp((d['amount'] ?? 0) as num),
                        style: const TextStyle(
                            fontSize: 18, fontWeight: FontWeight.w800)),
                    statusChip('pending'),
                  ],
                ),
                const SizedBox(height: 4),
                Text('${d['userName'] ?? ''}  •  ${d['userEmail'] ?? ''}',
                    style: const TextStyle(color: Colors.black54)),
                const SizedBox(height: 6),
                SelectableText('DANA: ${d['danaNumber']}',
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w700)),
                Text(fmt(d['createdAt']),
                    style: const TextStyle(color: Colors.black54)),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(
                    child: PressScale(child: FilledButton(
                      style: FilledButton.styleFrom(
                          backgroundColor: Colors.green),
                      onPressed: () => approveWd(context, w.id),
                      child: const Text('Terima'),
                    )),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: PressScale(child: FilledButton(
                      style: FilledButton.styleFrom(
                          backgroundColor: Colors.red),
                      onPressed: () => rejectWd(context, w.id),
                      child: const Text('Tolak'),
                    )),
                  ),
                ]),
              ],
            ),
          ),
        );
      },
    );
  }
}

/* ---------------- Admin: buka/tutup job & saldo user ---------------- */

/// Saklar global: kalau ditutup, user tidak bisa mengambil job baru.
class JobsSwitch extends StatelessWidget {
  const JobsSwitch({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: db.collection('settings').doc('app').snapshots(),
      builder: (context, snap) {
        final open = snap.data?.data()?['jobsOpen'] != false;
        return Card(
          margin: const EdgeInsets.only(bottom: 14),
          color: open ? Colors.green.shade50 : Colors.red.shade50,
          child: SwitchListTile(
            title: Text(
              open ? 'Pengerjaan job: DIBUKA' : 'Pengerjaan job: DITUTUP',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            subtitle: const Text(
                'Kalau ditutup, user tidak bisa mengambil job baru.'),
            value: open,
            onChanged: (v) => guard(
              context,
              () => db
                  .collection('settings')
                  .doc('app')
                  .set({'jobsOpen': v}, SetOptions(merge: true)),
              v ? 'Job dibuka.' : 'Job ditutup.',
            ),
          ),
        );
      },
    );
  }
}

class AmountInput {
  final int amount;
  final String note;
  const AmountInput(this.amount, this.note);
}

class AmountDialog extends StatefulWidget {
  final String title;
  const AmountDialog({super.key, required this.title});
  @override
  State<AmountDialog> createState() => _AmountDialogState();
}

class _AmountDialogState extends State<AmountDialog> {
  final amtC = TextEditingController();
  final noteC = TextEditingController();

  @override
  void dispose() {
    amtC.dispose();
    noteC.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: amtC,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
                labelText: 'Jumlah (Rp)'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: noteC,
            decoration: const InputDecoration(
                labelText: 'Catatan (opsional)'),
          ),
        ],
      ),
      actions: [
        PressScale(child: TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Batal'))),
        PressScale(child: FilledButton(
          onPressed: () {
            final a = int.tryParse(amtC.text.replaceAll(RegExp(r'\D'), '')) ?? 0;
            if (a <= 0) return;
            Navigator.pop(context, AmountInput(a, noteC.text.trim()));
          },
          child: const Text('Simpan'),
        )),
      ],
    );
  }
}

/// Tambah atau kurangi saldo user. Setiap perubahan dicatat di `adjustments`.
Future<void> adjustBalance(BuildContext c, Doc user, bool add) async {
  final name = '${user.data()['name'] ?? ''}';
  final input = await showDialog<AmountInput>(
    context: c,
    builder: (_) =>
        AmountDialog(title: '${add ? 'Tambah' : 'Kurangi'} saldo $name'),
  );
  if (input == null || !c.mounted) return;
  await guard(
      c,
      () => db.runTransaction((tx) async {
            final uRef = db.collection('users').doc(user.id);
            final u = await tx.get(uRef);
            final ud = u.data();
            if (ud == null) throw Exception('User tidak ditemukan');
            final bal = ((ud['balance'] ?? 0) as num).toInt();
            final next = add ? bal + input.amount : bal - input.amount;
            if (next < 0) {
              throw Exception(
                  'Saldo tidak boleh kurang dari 0 (saldo sekarang ${rp(bal)})');
            }
            tx.update(uRef, {'balance': next});
            tx.set(db.collection('adjustments').doc(), {
              'uid': user.id,
              'userName': ud['name'] ?? '',
              'userEmail': ud['email'] ?? '',
              'amount': add ? input.amount : -input.amount,
              'note': input.note,
              'balanceBefore': bal,
              'balanceAfter': next,
              'createdAt': FieldValue.serverTimestamp(),
            });
          }),
      add ? 'Saldo ditambah.' : 'Saldo dikurangi.');
}

class AdminUsers extends StatefulWidget {
  const AdminUsers({super.key});
  @override
  State<AdminUsers> createState() => _AdminUsersState();
}

class _AdminUsersState extends State<AdminUsers> {
  final searchC = TextEditingController();
  String q = '';

  @override
  void dispose() {
    searchC.dispose();
    super.dispose();
  }

  Widget _card(BuildContext context, Doc u) {
    final d = u.data();
    final bal = ((d['balance'] ?? 0) as num).toInt();
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${d['name'] ?? ''}',
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            Text('${d['email'] ?? ''}',
                style: const TextStyle(color: Colors.black54)),
            if ('${d['phone'] ?? ''}'.isNotEmpty)
              Text('Telepon: ${d['phone']}',
                  style: const TextStyle(color: Colors.black54)),
            const SizedBox(height: 6),
            Text('Saldo: ${rp(bal)}',
                style: const TextStyle(
                    fontWeight: FontWeight.w700, color: Colors.green)),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: PressScale(child: FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: Colors.green),
                  onPressed: () => adjustBalance(context, u, true),
                  child: const Text('Tambah'),
                )),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: PressScale(child: FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: Colors.red),
                  onPressed: () => adjustBalance(context, u, false),
                  child: const Text('Kurangi'),
                )),
              ),
            ]),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Snap>(
      stream: db.collection('users').snapshots(),
      builder: (context, snap) {
        if (snap.hasError) return ErrorBox(snap.error!);
        if (!snap.hasData) return const Loading();
        final docs = sorted(snap.data!).where((u) {
          final m = u.data();
          final t =
              '${m['name'] ?? ''} ${m['email'] ?? ''} ${m['phone'] ?? ''}'
                  .toLowerCase();
          return q.isEmpty || t.contains(q);
        }).toList();
        return ListView(
          padding: const EdgeInsets.all(14),
          children: [
            TextField(
              controller: searchC,
              onChanged: (v) => setState(() => q = v.trim().toLowerCase()),
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                labelText: 'Cari nama atau email',
              ),
            ),
            const SizedBox(height: 12),
            if (docs.isEmpty) const EmptyBox('Tidak ada user.'),
            for (final u in docs) _card(context, u),
          ],
        );
      },
    );
  }
}

/* ---------------- Chat admin (tiket) ---------------- */

String _preview(String t) {
  final s = t.replaceAll('\n', ' ').trim();
  return s.length > 80 ? '${s.substring(0, 80)}…' : s;
}

/// Kirim pesan dari user. Tiket dibuat otomatis pada pesan pertama
/// (id tiket = uid user), jadi tidak perlu membuat tiket manual.
Future<void> sendUserMessage(User u, String text) async {
  final tRef = db.collection('tickets').doc(u.uid);
  final t = await tRef.get();
  final batch = db.batch();
  if (!t.exists) {
    batch.set(tRef, {
      'uid': u.uid,
      'userName': nameOf(u),
      'userEmail': u.email ?? '',
      'status': 'open',
      'lastMessage': _preview(text),
      'lastAt': FieldValue.serverTimestamp(),
      'unreadAdmin': true,
      'unreadUser': false,
      'createdAt': FieldValue.serverTimestamp(),
    });
  } else {
    batch.update(tRef, {
      'status': 'open',
      'lastMessage': _preview(text),
      'lastAt': FieldValue.serverTimestamp(),
      'unreadAdmin': true,
    });
  }
  batch.set(tRef.collection('messages').doc(), {
    'sender': 'user',
    'text': text,
    'createdAt': FieldValue.serverTimestamp(),
  });
  await batch.commit();
}

/// Balasan admin untuk sebuah tiket.
Future<void> sendAdminMessage(String ticketId, String text) async {
  final tRef = db.collection('tickets').doc(ticketId);
  final batch = db.batch();
  batch.update(tRef, {
    'lastMessage': 'Admin: ${_preview(text)}',
    'lastAt': FieldValue.serverTimestamp(),
    'unreadUser': true,
    'unreadAdmin': false,
  });
  batch.set(tRef.collection('messages').doc(), {
    'sender': 'admin',
    'text': text,
    'createdAt': FieldValue.serverTimestamp(),
  });
  await batch.commit();
}

class ChatBubble extends StatelessWidget {
  final String text;
  final bool mine;
  final String time;
  const ChatBubble({
    super.key,
    required this.text,
    required this.mine,
    required this.time,
  });

  @override
  Widget build(BuildContext context) {
    final maxW = MediaQuery.of(context).size.width * 0.78;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(maxWidth: maxW),
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: mine ? kPrimary : Colors.white,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(18),
            topRight: const Radius.circular(18),
            bottomLeft: Radius.circular(mine ? 18 : 4),
            bottomRight: Radius.circular(mine ? 4 : 18),
          ),
          border: mine ? null : Border.all(color: const Color(0xFFE8EAF3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(
              text,
              style: TextStyle(color: mine ? Colors.white : Colors.black87),
            ),
            const SizedBox(height: 4),
            Text(
              time,
              style: TextStyle(
                fontSize: 10,
                color: mine ? Colors.white70 : Colors.grey,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Tampilan percakapan yang dipakai user dan admin.
/// [me] = 'user' atau 'admin' (pesan milik sendiri tampil di kanan).
class ChatView extends StatefulWidget {
  final String ticketId;
  final String me;
  final bool ticketExists;
  final String? closedNote;
  final String emptyText;
  final Future<void> Function(String text) onSend;
  const ChatView({
    super.key,
    required this.ticketId,
    required this.me,
    required this.ticketExists,
    required this.emptyText,
    required this.onSend,
    this.closedNote,
  });

  @override
  State<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends State<ChatView> {
  final c = TextEditingController();
  bool sending = false;

  @override
  void dispose() {
    c.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = c.text.trim();
    if (text.isEmpty || sending) return;
    setState(() => sending = true);
    try {
      await widget.onSend(text);
      c.clear();
    } catch (e) {
      if (mounted) toast(context, errText(e));
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  Widget _messages() {
    // Tiket belum ada (belum pernah kirim pesan): jangan baca pesan dulu.
    if (!widget.ticketExists) return EmptyBox(widget.emptyText);
    return StreamBuilder<Snap>(
      stream: db
          .collection('tickets')
          .doc(widget.ticketId)
          .collection('messages')
          .orderBy('createdAt', descending: true)
          .snapshots(),
      builder: (context, snap) {
        if (snap.hasError) return ErrorBox(snap.error!);
        if (!snap.hasData) return const Loading();
        final docs = snap.data!.docs;
        if (docs.isEmpty) return EmptyBox(widget.emptyText);
        return ListView.builder(
          reverse: true,
          padding: const EdgeInsets.all(14),
          itemCount: docs.length,
          itemBuilder: (context, i) {
            final d = docs[i].data();
            return ChatBubble(
              text: '${d['text'] ?? ''}',
              mine: d['sender'] == widget.me,
              time: fmt(d['createdAt']),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(child: _messages()),
        if (widget.closedNote != null)
          Container(
            width: double.infinity,
            color: Colors.orange.withOpacity(0.12),
            padding: const EdgeInsets.all(8),
            child: Text(
              widget.closedNote!,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12),
            ),
          ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    controller: c,
                    minLines: 1,
                    maxLines: 4,
                    maxLength: 1000,
                    decoration: const InputDecoration(
                      hintText: 'Tulis pesan...',
                      counterText: '',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                PressScale(child: IconButton.filled(
                  onPressed: sending ? null : _send,
                  icon: const Icon(Icons.send),
                )),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Tab "Chat Admin" untuk user. Tiket otomatis dibuat saat pesan pertama dikirim.
class ChatTab extends StatelessWidget {
  final User user;
  const ChatTab({super.key, required this.user});

  @override
  Widget build(BuildContext context) {
    final ref = db.collection('tickets').doc(user.uid);
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: ref.snapshots(),
      builder: (context, snap) {
        if (snap.hasError) return ErrorBox(snap.error!);
        if (!snap.hasData) return const Loading();
        final exists = snap.data!.exists;
        final d = snap.data!.data();
        if (exists && d?['unreadUser'] == true) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            ref.update({'unreadUser': false}).catchError((_) {});
          });
        }
        final closed = d?['status'] == 'closed';
        return Column(
          children: [
            Container(
              width: double.infinity,
              margin: const EdgeInsets.fromLTRB(14, 6, 14, 0),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: kPrimary.withOpacity(0.08),
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Text(
                'Ada kendala atau pertanyaan? Tulis pesan di sini. '
                'Tiket dibuat otomatis dan admin akan membalas.',
                style: TextStyle(fontSize: 13),
              ),
            ),
            Expanded(
              child: ChatView(
                ticketId: user.uid,
                me: 'user',
                ticketExists: exists,
                closedNote: closed
                    ? 'Tiket ini ditutup. Kirim pesan untuk membukanya lagi.'
                    : null,
                emptyText: 'Belum ada pesan.\nKetik pesan pertama kamu di bawah.',
                onSend: (t) => sendUserMessage(user, t),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Daftar tiket chat di admin panel.
class AdminChats extends StatelessWidget {
  const AdminChats({super.key});

  int _at(Doc t) {
    final x = t.data()['lastAt'];
    return x is Timestamp ? x.millisecondsSinceEpoch : 0x7fffffffffff;
  }

  Widget _tile(BuildContext context, Doc t) {
    final d = t.data();
    final unread = d['unreadAdmin'] == true;
    final closed = d['status'] == 'closed';
    final name = '${d['userName'] ?? ''}';
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => AdminChatPage(ticketId: t.id)),
        ),
        leading: CircleAvatar(
          child: Text(name.isEmpty ? '?' : name.substring(0, 1).toUpperCase()),
        ),
        title: Text(
          name,
          style: TextStyle(
              fontWeight: unread ? FontWeight.w800 : FontWeight.w600),
        ),
        subtitle: Text(
          '${d['lastMessage'] ?? ''}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(fmt(d['lastAt']),
                style: const TextStyle(fontSize: 11, color: Colors.grey)),
            const SizedBox(height: 4),
            if (unread)
              pill('Baru', Colors.red)
            else if (closed)
              pill('Ditutup', Colors.grey),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Snap>(
      stream: db.collection('tickets').snapshots(),
      builder: (context, snap) {
        if (snap.hasError) return ErrorBox(snap.error!);
        if (!snap.hasData) return const Loading();
        final docs = snap.data!.docs
            .where((t) => '${t.data()['lastMessage'] ?? ''}'.isNotEmpty)
            .toList();
        docs.sort((a, b) => _at(b).compareTo(_at(a)));
        if (docs.isEmpty) return const EmptyBox('Belum ada chat dari user.');
        return ListView(
          padding: const EdgeInsets.all(14),
          children: [for (final t in docs) _tile(context, t)],
        );
      },
    );
  }
}

/// Halaman percakapan satu tiket, untuk membalas user.
class AdminChatPage extends StatelessWidget {
  final String ticketId;
  const AdminChatPage({super.key, required this.ticketId});

  @override
  Widget build(BuildContext context) {
    final ref = db.collection('tickets').doc(ticketId);
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: ref.snapshots(),
      builder: (context, snap) {
        final d = snap.data?.data();
        if (d != null && d['unreadAdmin'] == true) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            ref.update({'unreadAdmin': false}).catchError((_) {});
          });
        }
        final closed = d?['status'] == 'closed';
        return Scaffold(
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${d?['userName'] ?? 'Chat'}',
                    style: const TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w800)),
                Text('${d?['userEmail'] ?? ''}',
                    style: const TextStyle(fontSize: 12, color: Colors.grey)),
              ],
            ),
            actions: [
              PressScale(child: TextButton(
                onPressed: d == null
                    ? null
                    : () => guard(
                          context,
                          () => ref.update({'status': closed ? 'open' : 'closed'}),
                          closed ? 'Tiket dibuka lagi.' : 'Tiket ditutup.',
                        ),
                child: Text(closed ? 'Buka lagi' : 'Tutup tiket'),
              )),
            ],
          ),
          body: ChatView(
            ticketId: ticketId,
            me: 'admin',
            ticketExists: d != null,
            closedNote: closed ? 'Tiket ini ditutup.' : null,
            emptyText: 'Belum ada pesan.',
            onSend: (t) => sendAdminMessage(ticketId, t),
          ),
        );
      },
    );
  }
}

/// Efek "ditekan": tombol mengecil sedikit saat disentuh lalu kembali halus.
/// Memakai Listener, jadi tidak mengganggu fungsi klik tombol aslinya.
class PressScale extends StatefulWidget {
  final Widget child;
  const PressScale({super.key, required this.child});

  @override
  State<PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<PressScale> {
  bool down = false;

  void _set(bool v) {
    if (down != v && mounted) setState(() => down = v);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => _set(true),
      onPointerUp: (_) => _set(false),
      onPointerCancel: (_) => _set(false),
      child: AnimatedScale(
        scale: down ? 0.95 : 1.0,
        duration: const Duration(milliseconds: 110),
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}
