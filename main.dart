import 'dart:async';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
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

class JobKuApp extends StatelessWidget {
  const JobKuApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'JobKu',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF2F6BFF),
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

bool isAdminUser(User u) =>
    (u.email ?? '').toLowerCase() == adminEmail.toLowerCase();

void toast(BuildContext c, String m) {
  ScaffoldMessenger.of(c)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(m)));
}

String errText(Object e) {
  if (e is FirebaseException) return 'Gagal: ${e.code}';
  return e.toString().replaceFirst('Exception: ', '');
}

Future<void> guard(BuildContext c, Future<void> Function() f,
    [String? ok]) async {
  try {
    await f();
    if (ok != null && c.mounted) toast(c, ok);
  } catch (e) {
    if (c.mounted) toast(c, errText(e));
  }
}

Future<bool> confirm(BuildContext c, String msg) async {
  final r = await showDialog<bool>(
    context: c,
    builder: (ctx) => AlertDialog(
      content: Text(msg),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Batal')),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Ya')),
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
}) {
  return StreamBuilder<Snap>(
    stream: stream,
    builder: (context, snap) {
      if (snap.hasError) return ErrorBox(snap.error!);
      if (!snap.hasData) return const Loading();
      final docs = sorted(snap.data!);
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
      stream: FirebaseAuth.instance.authStateChanges(),
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

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  bool busy = false;

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

  Future<void> _login() async {
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
          if (mounted) {
            toast(context,
                'Login gagal: ${errText(e)} | cadangan: ${errText(e2)}');
          }
        }
      } else if (mounted) {
        toast(context, 'Login gagal: ${errText(e)}');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('💼', style: TextStyle(fontSize: 56)),
                const SizedBox(height: 8),
                const Text('JobKu',
                    style:
                        TextStyle(fontSize: 30, fontWeight: FontWeight.w800)),
                const SizedBox(height: 8),
                const Text(
                  'Kerjakan job, dapatkan saldo, tarik ke DANA.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey),
                ),
                const SizedBox(height: 28),
                busy
                    ? const CircularProgressIndicator()
                    : FilledButton.icon(
                        onPressed: _login,
                        icon: const Icon(Icons.login),
                        label: const Text('Masuk dengan Google'),
                      ),
              ],
            ),
          ),
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
        await ref.set({
          'name': widget.user.displayName ?? '',
          'email': widget.user.email ?? '',
          'photo': widget.user.photoURL ?? '',
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
    final u = widget.user;
    final admin = isAdminUser(u);
    final pages = <Widget>[
      JobsTab(user: u),
      HistoryTab(user: u),
      WalletTab(user: u),
      if (admin) const AdminTab(),
    ];
    if (tab >= pages.length) tab = 0;
    return Scaffold(
      appBar: AppBar(
        title: const Text('💼 JobKu',
            style: TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          IconButton(
            tooltip: 'Keluar',
            onPressed: _logout,
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: pages[tab],
      bottomNavigationBar: NavigationBar(
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
          const NavigationDestination(
              icon: Icon(Icons.account_balance_wallet_outlined),
              selectedIcon: Icon(Icons.account_balance_wallet),
              label: 'Saldo'),
          if (admin)
            const NavigationDestination(
                icon: Icon(Icons.admin_panel_settings_outlined),
                selectedIcon: Icon(Icons.admin_panel_settings),
                label: 'Admin'),
        ],
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
            'takenByName': u.displayName ?? '',
          });
          if (sd == null) {
            tx.set(sRef, {
              'jobId': job.id,
              'jobTitle': jd['title'],
              'reward': jd['reward'],
              'uid': u.uid,
              'userName': u.displayName ?? '',
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
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(backgroundColor: Colors.green),
                  onPressed: () => finishJob(context, sub.id),
                  icon: const Icon(Icons.check_circle),
                  label: const Text('Sudah Selesai'),
                ),
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
        FilledButton.icon(
          onPressed: widget.open ? _search : null,
          icon: const Icon(Icons.search),
          label: const Text('Cari Job'),
        ),
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
                child: FilledButton(
                  onPressed: busy ? null : _take,
                  child: Text(busy ? 'Memproses...' : 'Ambil Job'),
                ),
              ),
              const SizedBox(width: 10),
              TextButton(
                onPressed: busy
                    ? null
                    : () => setState(() {
                          phase = FinderPhase.idle;
                          candidate = null;
                        }),
                child: const Text('Batal'),
              ),
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
        FilledButton.icon(
          onPressed: _search,
          icon: const Icon(Icons.refresh),
          label: const Text('Cari Lagi'),
        ),
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
      children: [body],
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
        'userName': widget.user.displayName ?? '',
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
                  colors: [Color(0xFF2F6BFF), Color(0xFF6D8DFF)]),
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
                        hintText: '08xxxxxxxxxx',
                        border: OutlineInputBorder()),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: amtC,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                        labelText: 'Jumlah penarikan',
                        hintText: '$minWithdraw',
                        border: const OutlineInputBorder()),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: busy ? null : _request,
                      child: Text(busy ? 'Mengirim...' : 'Ajukan Penarikan'),
                    ),
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
      length: 4,
      child: Column(
        children: [
          TabBar(isScrollable: true, tabs: [
            Tab(text: 'Kelola Job'),
            Tab(text: 'Review'),
            Tab(text: 'Penarikan'),
            Tab(text: 'Saldo User'),
          ]),
          Expanded(
            child: TabBarView(children: [
              AdminJobs(),
              AdminReview(),
              AdminWithdrawals(),
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
                    labelText: 'Nama job', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: descC,
                minLines: 3,
                maxLines: 6,
                decoration: const InputDecoration(
                    labelText: 'Deskripsi', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: rewardC,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                    labelText: 'Hadiah (Rp)',
                    hintText: '1000',
                    border: OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                    onPressed: _add, child: const Text('Tambah Job')),
              ),
            ],
          ),
        ),
      ),
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
                    active
                        ? pill('Dibuka', Colors.green)
                        : pill('Ditutup', Colors.red),
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
                    OutlinedButton(
                      onPressed: () => releaseJob(context, j),
                      child: const Text('Lepas Job'),
                    ),
                  OutlinedButton(
                    onPressed: () => guard(
                        context,
                        () => db
                            .collection('jobs')
                            .doc(j.id)
                            .update({'active': !active})),
                    child: Text(active ? 'Tutup Job' : 'Buka Job'),
                  ),
                  OutlinedButton(
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
                  ),
                ]),
              ],
            ),
          ),
        );
      },
      header: header,
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
                const SizedBox(height: 6),
                Text(rp((d['reward'] ?? 0) as num),
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, color: Colors.green)),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                          backgroundColor: Colors.green),
                      onPressed: () => approveSub(context, s.id),
                      child: const Text('Terima'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                          backgroundColor: Colors.red),
                      onPressed: () => rejectSub(context, s.id),
                      child: const Text('Tolak'),
                    ),
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
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                          backgroundColor: Colors.green),
                      onPressed: () => approveWd(context, w.id),
                      child: const Text('Terima'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                          backgroundColor: Colors.red),
                      onPressed: () => rejectWd(context, w.id),
                      child: const Text('Tolak'),
                    ),
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
                labelText: 'Jumlah (Rp)', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: noteC,
            decoration: const InputDecoration(
                labelText: 'Catatan (opsional)', border: OutlineInputBorder()),
          ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Batal')),
        FilledButton(
          onPressed: () {
            final a = int.tryParse(amtC.text.replaceAll(RegExp(r'\D'), '')) ?? 0;
            if (a <= 0) return;
            Navigator.pop(context, AmountInput(a, noteC.text.trim()));
          },
          child: const Text('Simpan'),
        ),
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
            const SizedBox(height: 6),
            Text('Saldo: ${rp(bal)}',
                style: const TextStyle(
                    fontWeight: FontWeight.w700, color: Colors.green)),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: Colors.green),
                  onPressed: () => adjustBalance(context, u, true),
                  child: const Text('Tambah'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: Colors.red),
                  onPressed: () => adjustBalance(context, u, false),
                  child: const Text('Kurangi'),
                ),
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
          final t = '${m['name'] ?? ''} ${m['email'] ?? ''}'.toLowerCase();
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
                border: OutlineInputBorder(),
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
