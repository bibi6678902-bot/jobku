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
    'submitted': 'Menunggu review',
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
  final c = colors[s] ?? Colors.grey;
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      color: c.withOpacity(0.12),
      borderRadius: BorderRadius.circular(99),
    ),
    child: Text(labels[s] ?? s,
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

  Future<void> _login() async {
    setState(() => busy = true);
    try {
      final account = await GoogleSignIn(serverClientId: webClientId).signIn();
      if (account == null) return;
      final auth = await account.authentication;
      final cred = GoogleAuthProvider.credential(
        idToken: auth.idToken,
        accessToken: auth.accessToken,
      );
      await FirebaseAuth.instance.signInWithCredential(cred);
    } catch (e) {
      if (mounted) toast(context, 'Login gagal: ${errText(e)}');
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

Future<void> takeJob(BuildContext c, User u, Doc job) => guard(c, () async {
      final d = job.data();
      await db.collection('submissions').doc('${job.id}_${u.uid}').set({
        'jobId': job.id,
        'jobTitle': d['title'],
        'reward': d['reward'],
        'uid': u.uid,
        'userName': u.displayName ?? '',
        'userEmail': u.email ?? '',
        'status': 'taken',
        'createdAt': FieldValue.serverTimestamp(),
      });
    }, 'Job diambil. Kerjakan lalu tekan Selesai.');

Future<void> finishJob(BuildContext c, String id) => guard(
    c,
    () => db.collection('submissions').doc(id).update({
          'status': 'submitted',
          'submittedAt': FieldValue.serverTimestamp(),
        }),
    'Terkirim, menunggu review admin.');

Future<void> retakeJob(BuildContext c, String id) => guard(
    c,
    () => db.collection('submissions').doc(id).update({'status': 'taken'}),
    'Silakan kerjakan lagi.');

class JobsTab extends StatelessWidget {
  final User user;
  const JobsTab({super.key, required this.user});

  Widget _card(BuildContext context, Doc job, Doc? sub) {
    final d = job.data();
    final st = sub?.data()['status'] as String?;
    Widget action;
    if (sub == null) {
      action = FilledButton(
        onPressed: () => takeJob(context, user, job),
        child: const Text('Ambil Job'),
      );
    } else if (st == 'taken') {
      action = FilledButton(
        style: FilledButton.styleFrom(backgroundColor: Colors.green),
        onPressed: () => finishJob(context, sub.id),
        child: const Text('Selesai Mengerjakan'),
      );
    } else if (st == 'rejected') {
      action = Row(mainAxisSize: MainAxisSize.min, children: [
        statusChip('rejected'),
        const SizedBox(width: 6),
        TextButton(
          onPressed: () => retakeJob(context, sub.id),
          child: const Text('Kerjakan Lagi'),
        ),
      ]);
    } else {
      action = statusChip(st ?? '');
    }
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${d['title'] ?? ''}',
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text('${d['description'] ?? ''}',
                style: const TextStyle(color: Colors.black54)),
            const SizedBox(height: 10),
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                Text('Hadiah ${rp((d['reward'] ?? 0) as num)}',
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, color: Colors.green)),
                action,
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Snap>(
      stream: db.collection('jobs').snapshots(),
      builder: (context, jobsSnap) {
        return StreamBuilder<Snap>(
          stream: db
              .collection('submissions')
              .where('uid', isEqualTo: user.uid)
              .snapshots(),
          builder: (context, subSnap) {
            if (jobsSnap.hasError) return ErrorBox(jobsSnap.error!);
            if (subSnap.hasError) return ErrorBox(subSnap.error!);
            if (!jobsSnap.hasData || !subSnap.hasData) return const Loading();
            final subs = <String, Doc>{
              for (final d in subSnap.data!.docs) '${d.data()['jobId']}': d
            };
            final jobs = sorted(jobsSnap.data!)
                .where((j) => j.data()['active'] != false)
                .toList();
            if (jobs.isEmpty) return const EmptyBox('Belum ada job tersedia.');
            return ListView(
              padding: const EdgeInsets.all(14),
              children: [for (final j in jobs) _card(context, j, subs[j.id])],
            );
          },
        );
      },
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

Future<void> rejectSub(BuildContext c, String id) => guard(
    c,
    () => db.collection('submissions').doc(id).update({
          'status': 'rejected',
          'reviewedAt': FieldValue.serverTimestamp(),
        }),
    'Ditolak.');

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
      length: 3,
      child: Column(
        children: [
          TabBar(tabs: [
            Tab(text: 'Kelola Job'),
            Tab(text: 'Review'),
            Tab(text: 'Penarikan'),
          ]),
          Expanded(
            child: TabBarView(children: [
              AdminJobs(),
              AdminReview(),
              AdminWithdrawals(),
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
          'createdAt': FieldValue.serverTimestamp(),
        });
        titleC.clear();
        descC.clear();
        rewardC.clear();
      }, 'Job ditambahkan.');

  @override
  Widget build(BuildContext context) {
    final header = <Widget>[
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
                    statusChip(active ? 'approved' : 'rejected'),
                  ],
                ),
                const SizedBox(height: 4),
                Text('${d['description'] ?? ''}',
                    style: const TextStyle(color: Colors.black54)),
                const SizedBox(height: 6),
                Text(rp((d['reward'] ?? 0) as num),
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, color: Colors.green)),
                const SizedBox(height: 6),
                Wrap(spacing: 8, children: [
                  OutlinedButton(
                    onPressed: () => guard(
                        context,
                        () => db
                            .collection('jobs')
                            .doc(j.id)
                            .update({'active': !active})),
                    child: Text(active ? 'Nonaktifkan' : 'Aktifkan'),
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
