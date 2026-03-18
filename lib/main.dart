import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image/image.dart' as img;
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:crypto/crypto.dart';
import 'firebase_options.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  final prefs = await SharedPreferences.getInstance();
  final savedId = prefs.getString('currentUserId');
  final savedUsername = prefs.getString('currentUserName');
  runApp(LiftTrackerApp(savedId: savedId, savedUsername: savedUsername));
}

// ─── Data Model ──────────────────────────────────────────────────────────────

class RepRecord {
  final int reps;
  final double weight;
  final String unit;
  final DateTime date;

  RepRecord({
    required this.reps,
    required this.weight,
    required this.unit,
    required this.date,
  });

  Map<String, dynamic> toJson() => {
        'reps': reps,
        'weight': weight,
        'unit': unit,
        'date': date.toIso8601String(),
      };

  factory RepRecord.fromJson(Map<String, dynamic> j) => RepRecord(
        reps: j['reps'] as int,
        weight: (j['weight'] as num).toDouble(),
        unit: j['unit'] as String? ?? 'lbs',
        date: DateTime.parse(j['date'] as String),
      );
}

class Lift {
  String name;
  List<RepRecord> history; // every logged record
  Map<int, RepRecord> bests; // best weight per rep count (computed)
  List<Comment> comments;
  Map<String, List<String>> reactions;

  Lift({
    required this.name,
    List<RepRecord>? history,
    Map<int, RepRecord>? bests,
    List<Comment>? comments,
    Map<String, List<String>>? reactions,
  })  : history = history ?? [],
        bests = bests ?? {},
        comments = comments ?? [],
        reactions = reactions ?? {};

  /// Rebuild `bests` from the full `history`.
  void recomputeBests() {
    bests.clear();
    for (final r in history) {
      final cur = bests[r.reps];
      if (cur == null || r.weight > cur.weight) bests[r.reps] = r;
    }
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'history': history.map((r) => r.toJson()).toList(),
        'bests': bests.map((k, v) => MapEntry(k.toString(), v.toJson())),
        'comments': comments.map((c) => c.toJson()).toList(),
        'reactions': reactions.map((k, v) => MapEntry(k, v)),
      };

  factory Lift.fromJson(Map<String, dynamic> j) {
    // Load stored history; if absent (old data), seed it from bests.
    final history = (j['history'] as List<dynamic>? ?? [])
        .map((e) => RepRecord.fromJson(e as Map<String, dynamic>))
        .toList();
    if (history.isEmpty && j['bests'] != null) {
      (j['bests'] as Map<String, dynamic>).forEach((k, v) {
        history.add(RepRecord.fromJson(v as Map<String, dynamic>));
      });
    }
    final lift = Lift(
      name: j['name'] as String,
      history: history,
      comments: (j['comments'] as List<dynamic>? ?? [])
          .map((e) => Comment.fromJson(e as Map<String, dynamic>))
          .toList(),
      reactions: (j['reactions'] as Map<String, dynamic>? ?? {}).map(
        (k, v) => MapEntry(
            k, (v as List<dynamic>).map((e) => e as String).toList()),
      ),
    );
    lift.recomputeBests();
    return lift;
  }
}

class Profile {
  String? id; // Firestore document ID
  String name;
  String username;      // login handle
  String? passwordHash; // SHA-256 — null means not set up
  String? email;
  bool isAdmin;
  List<Lift> lifts;
  List<Workout> workouts;
  List<String> goals;
  String? photoData; // base64 data URL
  List<ProgramDay> program;

  Profile({
    this.id,
    required this.name,
    String? username,
    this.passwordHash,
    this.email,
    this.isAdmin = false,
    List<Lift>? lifts,
    List<Workout>? workouts,
    List<String>? goals,
    this.photoData,
    List<ProgramDay>? program,
  })  : username = username ?? name,
        lifts = lifts ?? [],
        workouts = workouts ?? [],
        goals = goals ?? [],
        program = program ?? [];

  Map<String, dynamic> toJson() => {
        'name': name,
        'username': username,
        if (passwordHash != null) 'passwordHash': passwordHash,
        if (email != null) 'email': email,
        if (isAdmin) 'isAdmin': true,
        'lifts': lifts.map((l) => l.toJson()).toList(),
        'workouts': workouts.map((w) => w.toJson()).toList(),
        'goals': goals,
        if (photoData != null) 'photoData': photoData,
        'program': program.map((d) => d.toJson()).toList(),
      };

  factory Profile.fromJson(Map<String, dynamic> j, {String? id}) {
    final name = j['name'] as String;
    return Profile(
      id: id,
      name: name,
      username: j['username'] as String? ?? name,
      passwordHash: j['passwordHash'] as String?,
      email: j['email'] as String?,
      isAdmin: j['isAdmin'] as bool? ?? false,
      lifts: (j['lifts'] as List<dynamic>? ?? [])
          .map((e) => Lift.fromJson(e as Map<String, dynamic>))
          .toList(),
      workouts: (j['workouts'] as List<dynamic>? ?? [])
          .map((e) => Workout.fromJson(e as Map<String, dynamic>))
          .toList(),
      goals: (j['goals'] as List<dynamic>? ?? [])
          .map((e) => e as String)
          .toList(),
      photoData: j['photoData'] as String?,
      program: (j['program'] as List<dynamic>? ?? [])
          .map((e) => ProgramDay.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

class Comment {
  final String author;
  final String text;
  final DateTime date;

  Comment({required this.author, required this.text, required this.date});

  Map<String, dynamic> toJson() => {
        'author': author,
        'text': text,
        'date': date.toIso8601String(),
      };

  factory Comment.fromJson(Map<String, dynamic> j) => Comment(
        author: j['author'] as String,
        text: j['text'] as String,
        date: DateTime.parse(j['date'] as String),
      );
}

class WorkoutSet {
  final int reps;
  final double weight;
  final String unit;

  WorkoutSet({required this.reps, required this.weight, required this.unit});

  Map<String, dynamic> toJson() =>
      {'reps': reps, 'weight': weight, 'unit': unit};

  factory WorkoutSet.fromJson(Map<String, dynamic> j) => WorkoutSet(
        reps: j['reps'] as int,
        weight: (j['weight'] as num).toDouble(),
        unit: j['unit'] as String? ?? 'lbs',
      );
}

enum WorkoutType {
  strength, amrap, emom, forTime;

  String get label => switch (this) {
        WorkoutType.strength => 'Strength',
        WorkoutType.amrap => 'AMRAP',
        WorkoutType.emom => 'EMOM',
        WorkoutType.forTime => 'For Time',
      };
}

class WorkoutExercise {
  String liftName;
  List<WorkoutSet> sets; // strength
  int reps;             // functional
  double? weight;       // functional (optional)
  String unit;
  String? otherType;    // 'Reps' | 'Weight' | 'Height' | 'RPE'
  String? otherValue;

  WorkoutExercise({
    required this.liftName,
    List<WorkoutSet>? sets,
    this.reps = 10,
    this.weight,
    this.unit = 'lbs',
    this.otherType,
    this.otherValue,
  }) : sets = sets ?? [];

  Map<String, dynamic> toJson() => {
        'liftName': liftName,
        'sets': sets.map((s) => s.toJson()).toList(),
        'reps': reps,
        if (weight != null) 'weight': weight,
        'unit': unit,
        if (otherType != null) 'otherType': otherType,
        if (otherValue != null && otherValue!.isNotEmpty) 'otherValue': otherValue,
      };

  factory WorkoutExercise.fromJson(Map<String, dynamic> j) => WorkoutExercise(
        liftName: j['liftName'] as String,
        sets: (j['sets'] as List<dynamic>? ?? [])
            .map((e) => WorkoutSet.fromJson(e as Map<String, dynamic>))
            .toList(),
        reps: j['reps'] as int? ?? 10,
        weight: (j['weight'] as num?)?.toDouble(),
        unit: j['unit'] as String? ?? 'lbs',
        otherType: j['otherType'] as String?,
        otherValue: j['otherValue'] as String?,
      );
}

class Workout {
  DateTime date;
  WorkoutType type;
  int? timeCap; // minutes
  String? result;
  List<WorkoutExercise> exercises;
  List<Comment> comments;
  Map<String, List<String>> reactions;

  Workout({
    required this.date,
    this.type = WorkoutType.strength,
    this.timeCap,
    this.result,
    List<WorkoutExercise>? exercises,
    List<Comment>? comments,
    Map<String, List<String>>? reactions,
  })  : exercises = exercises ?? [],
        comments = comments ?? [],
        reactions = reactions ?? {};

  Map<String, dynamic> toJson() => {
        'date': date.toIso8601String(),
        'type': type.name,
        if (timeCap != null) 'timeCap': timeCap,
        if (result != null && result!.isNotEmpty) 'result': result,
        'exercises': exercises.map((e) => e.toJson()).toList(),
        'comments': comments.map((c) => c.toJson()).toList(),
        'reactions': reactions.map((k, v) => MapEntry(k, v)),
      };

  factory Workout.fromJson(Map<String, dynamic> j) => Workout(
        date: DateTime.parse(j['date'] as String),
        type: WorkoutType.values.firstWhere(
          (t) => t.name == (j['type'] as String? ?? 'strength'),
          orElse: () => WorkoutType.strength,
        ),
        timeCap: j['timeCap'] as int?,
        result: j['result'] as String?,
        exercises: (j['exercises'] as List<dynamic>? ?? [])
            .map((e) => WorkoutExercise.fromJson(e as Map<String, dynamic>))
            .toList(),
        comments: (j['comments'] as List<dynamic>? ?? [])
            .map((e) => Comment.fromJson(e as Map<String, dynamic>))
            .toList(),
        reactions: (j['reactions'] as Map<String, dynamic>? ?? {}).map(
          (k, v) => MapEntry(
              k, (v as List<dynamic>).map((e) => e as String).toList()),
        ),
      );
}

// ─── Program Models ──────────────────────────────────────────────────────────

class ProgramSet {
  int reps;
  double? weight;
  String unit;
  double? rpe;
  SetStatus status;

  ProgramSet({
    this.reps = 5,
    this.weight,
    this.unit = 'lbs',
    this.rpe,
    this.status = SetStatus.none,
  });

  Map<String, dynamic> toJson() => {
        'reps': reps,
        if (weight != null) 'weight': weight,
        'unit': unit,
        if (rpe != null) 'rpe': rpe,
        'status': status.name,
      };

  factory ProgramSet.fromJson(Map<String, dynamic> j) => ProgramSet(
        reps: j['reps'] as int? ?? 5,
        weight: (j['weight'] as num?)?.toDouble(),
        unit: j['unit'] as String? ?? 'lbs',
        rpe: (j['rpe'] as num?)?.toDouble(),
        status: SetStatus.values.firstWhere(
          (s) => s.name == (j['status'] as String? ?? 'none'),
          orElse: () => SetStatus.none,
        ),
      );
}

class ProgramExercise {
  String name;
  List<ProgramSet> sets;

  ProgramExercise({required this.name, List<ProgramSet>? sets})
      : sets = sets ?? [];

  Map<String, dynamic> toJson() => {
        'name': name,
        'sets': sets.map((s) => s.toJson()).toList(),
      };

  factory ProgramExercise.fromJson(Map<String, dynamic> j) => ProgramExercise(
        name: j['name'] as String,
        sets: (j['sets'] as List<dynamic>? ?? [])
            .map((e) => ProgramSet.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

class ProgramDay {
  DateTime date;
  List<ProgramExercise> exercises;

  ProgramDay({required this.date, List<ProgramExercise>? exercises})
      : exercises = exercises ?? [];

  Map<String, dynamic> toJson() => {
        'date': date.toIso8601String(),
        'exercises': exercises.map((e) => e.toJson()).toList(),
      };

  factory ProgramDay.fromJson(Map<String, dynamic> j) => ProgramDay(
        date: DateTime.parse(j['date'] as String),
        exercises: (j['exercises'] as List<dynamic>? ?? [])
            .map((e) => ProgramExercise.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

// ─── Storage ─────────────────────────────────────────────────────────────────

class LiftStore {
  static final _col = FirebaseFirestore.instance.collection('profiles');

  static Stream<List<Profile>> stream() => _col.snapshots().map(
        (snap) => snap.docs
            .map((doc) => Profile.fromJson(doc.data(), id: doc.id))
            .toList(),
      );

  static Future<void> saveProfile(Profile p) async {
    if (p.id == null) {
      final doc = await _col.add(p.toJson());
      p.id = doc.id;
    } else {
      await _col.doc(p.id).set(p.toJson());
    }
  }

  static Future<void> deleteProfile(String id) =>
      _col.doc(id).delete();
}

// ─── App ─────────────────────────────────────────────────────────────────────

class LiftTrackerApp extends StatelessWidget {
  final String? savedId;
  final String? savedUsername;

  const LiftTrackerApp({super.key, this.savedId, this.savedUsername});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Lift Tracker',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1565C0),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: _AuthGate(savedId: savedId, savedUsername: savedUsername),
    );
  }
}

/// Checks if a session is saved. If yes, loads the profile and jumps straight
/// to HomeScreen. Otherwise shows SignInScreen.
class _AuthGate extends StatefulWidget {
  final String? savedId;
  final String? savedUsername;
  const _AuthGate({this.savedId, this.savedUsername});

  @override
  State<_AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<_AuthGate> {
  late Future<Profile?> _profileFuture;

  @override
  void initState() {
    super.initState();
    _profileFuture = _load();
  }

  Future<Profile?> _load() async {
    if (widget.savedId == null) return null;
    final doc = await FirebaseFirestore.instance
        .collection('profiles')
        .doc(widget.savedId)
        .get();
    if (!doc.exists) return null;
    return Profile.fromJson(doc.data()!, id: doc.id);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Profile?>(
      future: _profileFuture,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Scaffold(
              body: Center(child: CircularProgressIndicator()));
        }
        final profile = snap.data;
        if (profile == null) {
          return SignInScreen(prefilledUsername: widget.savedUsername);
        }
        return HomeScreen(
          profile: profile,
          currentUserId: profile.id!,
          currentUserName: profile.username,
          onChanged: () => LiftStore.saveProfile(profile),
        );
      },
    );
  }
}

// ─── Auth Helpers ────────────────────────────────────────────────────────────

String _hashPassword(String password) =>
    sha256.convert(utf8.encode(password)).toString();

void _navigateToHome(BuildContext context, Profile profile) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('currentUserId', profile.id!);
  await prefs.setString('currentUserName', profile.username);
  if (!context.mounted) return;
  Navigator.of(context).pushReplacement(
    MaterialPageRoute(
      builder: (_) => HomeScreen(
        profile: profile,
        currentUserId: profile.id!,
        currentUserName: profile.username,
        onChanged: () => LiftStore.saveProfile(profile),
      ),
    ),
  );
}

// ─── Sign In Screen ───────────────────────────────────────────────────────────

class SignInScreen extends StatefulWidget {
  final String? prefilledUsername;
  const SignInScreen({super.key, this.prefilledUsername});

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  late final TextEditingController _userCtrl;
  final _pwCtrl = TextEditingController();
  bool _obscure = true;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _userCtrl = TextEditingController(text: widget.prefilledUsername ?? '');
  }

  @override
  void dispose() {
    _userCtrl.dispose();
    _pwCtrl.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    final username = _userCtrl.text.trim();
    final password = _pwCtrl.text;
    if (username.isEmpty || password.isEmpty) {
      setState(() => _error = 'Please enter your username and password.');
      return;
    }
    setState(() { _loading = true; _error = null; });
    final snap = await FirebaseFirestore.instance
        .collection('profiles')
        .where('username', isEqualTo: username)
        .limit(1)
        .get();
    if (snap.docs.isEmpty) {
      setState(() { _error = 'No account found with that username.'; _loading = false; });
      return;
    }
    final profile = Profile.fromJson(snap.docs.first.data(), id: snap.docs.first.id);
    if (profile.passwordHash == null) {
      // No password set — prompt to create one
      setState(() => _loading = false);
      if (!mounted) return;
      _promptSetPassword(profile);
      return;
    }
    if (profile.passwordHash != _hashPassword(password)) {
      setState(() { _error = 'Incorrect password.'; _loading = false; });
      _pwCtrl.clear();
      return;
    }
    if (!mounted) return;
    _navigateToHome(context, profile);
  }

  void _promptSetPassword(Profile profile) {
    final pw1 = TextEditingController();
    final pw2 = TextEditingController();
    String? dialogError;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) => AlertDialog(
          title: Text('Set password for ${profile.name}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'This account has no password yet. Create one to continue.',
                style: TextStyle(fontSize: 13, color: Colors.white60),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: pw1,
                obscureText: true,
                decoration: const InputDecoration(
                    labelText: 'New password',
                    border: OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: pw2,
                obscureText: true,
                decoration: const InputDecoration(
                    labelText: 'Confirm password',
                    border: OutlineInputBorder()),
              ),
              if (dialogError != null) ...[
                const SizedBox(height: 8),
                Text(dialogError!,
                    style: const TextStyle(
                        color: Colors.redAccent, fontSize: 12)),
              ],
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel')),
            FilledButton(
              onPressed: () async {
                final p1 = pw1.text;
                final p2 = pw2.text;
                if (p1.isEmpty) {
                  setDialog(() => dialogError = 'Password cannot be empty.');
                  return;
                }
                if (p1 != p2) {
                  setDialog(() => dialogError = 'Passwords do not match.');
                  return;
                }
                profile.passwordHash = _hashPassword(p1);
                await LiftStore.saveProfile(profile);
                if (!ctx.mounted) return;
                Navigator.pop(ctx);
                if (!mounted) return;
                _navigateToHome(context, profile);
              },
              child: const Text('Set Password'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 36),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.fitness_center, size: 64, color: cs.primary),
                const SizedBox(height: 16),
                const Text('Lift Tracker',
                    style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                const Text('Sign in to continue',
                    style: TextStyle(fontSize: 14, color: Colors.white54)),
                const SizedBox(height: 40),
                TextField(
                  controller: _userCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Username',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.person_outline),
                  ),
                  onChanged: (_) => setState(() => _error = null),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _pwCtrl,
                  obscureText: _obscure,
                  autofocus: widget.prefilledUsername != null,
                  decoration: InputDecoration(
                    labelText: 'Password',
                    border: const OutlineInputBorder(),
                    prefixIcon: const Icon(Icons.lock_outline),
                    suffixIcon: IconButton(
                      icon: Icon(_obscure
                          ? Icons.visibility_off
                          : Icons.visibility),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                  ),
                  onSubmitted: (_) => _signIn(),
                  onChanged: (_) => setState(() => _error = null),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!,
                      style: const TextStyle(color: Colors.redAccent)),
                ],
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _loading ? null : _signIn,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      child: _loading
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white))
                          : const Text('Sign In',
                              style: TextStyle(fontSize: 16)),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    const Expanded(child: Divider()),
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 12),
                      child: Text('or',
                          style: TextStyle(color: Colors.white38)),
                    ),
                    const Expanded(child: Divider()),
                  ],
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const CreateProfileScreen()),
                    ),
                    icon: const Icon(Icons.person_add_outlined),
                    label: const Padding(
                      padding: EdgeInsets.symmetric(vertical: 14),
                      child: Text('Create New Profile',
                          style: TextStyle(fontSize: 16)),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Create Profile Screen ────────────────────────────────────────────────────

class CreateProfileScreen extends StatefulWidget {
  const CreateProfileScreen({super.key});

  @override
  State<CreateProfileScreen> createState() => _CreateProfileScreenState();
}

class _CreateProfileScreenState extends State<CreateProfileScreen> {
  final _userCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _pwCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  bool _obscure1 = true;
  bool _obscure2 = true;
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _userCtrl.dispose();
    _emailCtrl.dispose();
    _pwCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final username = _userCtrl.text.trim();
    final email = _emailCtrl.text.trim();
    final pw = _pwCtrl.text;
    final confirm = _confirmCtrl.text;

    if (username.isEmpty) {
      setState(() => _error = 'Username is required.');
      return;
    }
    if (email.isEmpty || !email.contains('@')) {
      setState(() => _error = 'Enter a valid email address.');
      return;
    }
    if (pw.length < 4) {
      setState(() => _error = 'Password must be at least 4 characters.');
      return;
    }
    if (pw != confirm) {
      setState(() => _error = 'Passwords do not match.');
      return;
    }

    setState(() { _loading = true; _error = null; });

    // Check username uniqueness
    final existing = await FirebaseFirestore.instance
        .collection('profiles')
        .where('username', isEqualTo: username)
        .limit(1)
        .get();
    if (existing.docs.isNotEmpty) {
      setState(() {
        _error = 'That username is already taken.';
        _loading = false;
      });
      return;
    }

    final profile = Profile(
      name: username,
      username: username,
      passwordHash: _hashPassword(pw),
      email: email,
    );
    await LiftStore.saveProfile(profile);
    if (!mounted) return;
    _navigateToHome(context, profile);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Create Profile',
            style: TextStyle(fontWeight: FontWeight.bold)),
        centerTitle: true,
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 36, vertical: 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(Icons.person_add, size: 56, color: cs.primary),
                const SizedBox(height: 12),
                const Text('Set up your account',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 16, color: Colors.white54)),
                const SizedBox(height: 32),
                TextField(
                  controller: _userCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Username',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.person_outline),
                    helperText: 'This is how others will see you',
                  ),
                  onChanged: (_) => setState(() => _error = null),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _emailCtrl,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(
                    labelText: 'Email',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.email_outlined),
                  ),
                  onChanged: (_) => setState(() => _error = null),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _pwCtrl,
                  obscureText: _obscure1,
                  decoration: InputDecoration(
                    labelText: 'Password',
                    border: const OutlineInputBorder(),
                    prefixIcon: const Icon(Icons.lock_outline),
                    suffixIcon: IconButton(
                      icon: Icon(_obscure1
                          ? Icons.visibility_off
                          : Icons.visibility),
                      onPressed: () =>
                          setState(() => _obscure1 = !_obscure1),
                    ),
                  ),
                  onChanged: (_) => setState(() => _error = null),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _confirmCtrl,
                  obscureText: _obscure2,
                  decoration: InputDecoration(
                    labelText: 'Confirm Password',
                    border: const OutlineInputBorder(),
                    prefixIcon: const Icon(Icons.lock_outline),
                    suffixIcon: IconButton(
                      icon: Icon(_obscure2
                          ? Icons.visibility_off
                          : Icons.visibility),
                      onPressed: () =>
                          setState(() => _obscure2 = !_obscure2),
                    ),
                  ),
                  onSubmitted: (_) => _create(),
                  onChanged: (_) => setState(() => _error = null),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!,
                      style: const TextStyle(color: Colors.redAccent)),
                ],
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _loading ? null : _create,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    child: _loading
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : const Text('Create Profile',
                            style: TextStyle(fontSize: 16)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Profile Screen ───────────────────────────────────────────────────────────

class ProfileScreen extends StatefulWidget {
  final String currentUserId;
  final String currentUserName;

  const ProfileScreen(
      {super.key,
      required this.currentUserId,
      required this.currentUserName});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  void _addProfile() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('New Profile'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(hintText: 'e.g. Robert'),
          onSubmitted: (_) => _confirmAdd(controller.text),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () => _confirmAdd(controller.text),
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }

  void _confirmAdd(String name) {
    name = name.trim();
    if (name.isEmpty) return;
    Navigator.pop(context);
    LiftStore.saveProfile(Profile(name: name));
  }

  void _deleteProfile(Profile profile) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete profile?'),
        content: Text('Remove "${profile.name}" and all their lifts?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () {
              Navigator.pop(context);
              LiftStore.deleteProfile(profile.id!);
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  String _initials(String name) {
    final parts = name.trim().split(' ');
    if (parts.length >= 2) {
      return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    }
    return name.substring(0, name.length >= 2 ? 2 : 1).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Lift Tracker',
            style: TextStyle(fontWeight: FontWeight.bold)),
        centerTitle: true,
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.swap_horiz, size: 18),
            label: Text(widget.currentUserName,
                style: const TextStyle(fontSize: 13)),
            onPressed: () async {
              final nav = Navigator.of(context);
              final prefs = await SharedPreferences.getInstance();
              await prefs.remove('currentUserId');
              await prefs.remove('currentUserName');
              nav.pushReplacement(
                MaterialPageRoute(
                    builder: (_) => const SignInScreen()),
              );
            },
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: StreamBuilder<List<Profile>>(
        stream: LiftStore.stream(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final profiles = snapshot.data ?? [];
          if (profiles.isEmpty) {
            return const Center(
              child: Text(
                'No profiles yet.\nTap + to create one.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16, color: Colors.white54),
              ),
            );
          }
          return GridView.builder(
            padding: const EdgeInsets.all(20),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 200,
              mainAxisSpacing: 16,
              crossAxisSpacing: 16,
              childAspectRatio: 1,
            ),
            itemCount: profiles.length,
            itemBuilder: (context, i) {
              final profile = profiles[i];
              return GestureDetector(
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => HomeScreen(
                      profile: profile,
                      currentUserId: widget.currentUserId,
                      currentUserName: widget.currentUserName,
                      onChanged: () => LiftStore.saveProfile(profile),
                    ),
                  ),
                ),
                onLongPress: () => _deleteProfile(profile),
                child: Card(
                  margin: EdgeInsets.zero,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      CircleAvatar(
                        radius: 36,
                        backgroundColor:
                            Theme.of(context).colorScheme.primaryContainer,
                        backgroundImage: profile.photoData != null
                            ? NetworkImage(profile.photoData!)
                            : null,
                        child: profile.photoData == null
                            ? Text(
                                _initials(profile.name),
                                style: TextStyle(
                                  fontSize: 24,
                                  fontWeight: FontWeight.bold,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onPrimaryContainer,
                                ),
                              )
                            : null,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        profile.name,
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w600),
                        textAlign: TextAlign.center,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${profile.lifts.length} lift${profile.lifts.length == 1 ? '' : 's'}',
                        style: const TextStyle(
                            fontSize: 13, color: Colors.white54),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addProfile,
        icon: const Icon(Icons.person_add),
        label: const Text('Add Profile'),
      ),
    );
  }
}

// ─── Home Screen ─────────────────────────────────────────────────────────────

class HomeScreen extends StatefulWidget {
  final Profile profile;
  final String currentUserId;
  final String currentUserName;
  final VoidCallback onChanged;

  const HomeScreen({
    super.key,
    required this.profile,
    required this.currentUserId,
    required this.currentUserName,
    required this.onChanged,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  List<Lift> get lifts => widget.profile.lifts;
  List<Workout> get workouts => widget.profile.workouts;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _tabController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  String _fmtDate(DateTime d) {
    const m = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${m[d.month - 1]} ${d.day}, ${d.year}';
  }

  String _initials(String name) {
    final parts = name.trim().split(' ');
    if (parts.length >= 2) return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    return name.substring(0, name.length >= 2 ? 2 : 1).toUpperCase();
  }

  void _logWorkout() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => WorkoutScreen(
          profile: widget.profile,
          onSaved: () {
            setState(() {});
            widget.onChanged();
          },
        ),
      ),
    );
  }

  void _addLift() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('New Lift'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(hintText: 'e.g. Back Squat'),
          onSubmitted: (_) => _confirmAdd(controller.text),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () => _confirmAdd(controller.text),
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }

  void _confirmAdd(String name) {
    name = name.trim();
    if (name.isEmpty) return;
    Navigator.pop(context);
    setState(() => lifts.add(Lift(name: name)));
    widget.onChanged();
  }

  void _deleteLift(int index) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete lift?'),
        content: Text('Remove "${lifts[index].name}" and all its records?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () {
              Navigator.pop(context);
              setState(() => lifts.removeAt(index));
              widget.onChanged();
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  String _subtitle(Lift lift) {
    if (lift.bests.isEmpty) return 'No records yet';
    final sorted = lift.bests.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return sorted.map((e) {
      final w = e.value.weight % 1 == 0
          ? e.value.weight.toInt().toString()
          : e.value.weight.toStringAsFixed(1);
      return '${e.key}RM: $w ${e.value.unit}';
    }).join('  ·  ');
  }

  Widget _reactionSummary(Map<String, List<String>> reactions) {
    final active = reactions.entries.where((e) => e.value.isNotEmpty).toList();
    if (active.isEmpty) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: active
          .map((e) => Padding(
                padding: const EdgeInsets.only(right: 2),
                child: Text(
                  e.value.length > 1 ? '${e.key}${e.value.length}' : e.key,
                  style: const TextStyle(fontSize: 13),
                ),
              ))
          .toList(),
    );
  }

  Widget _sectionHeader(String title, IconData icon) {
    return Row(children: [
      Icon(icon, size: 16, color: Theme.of(context).colorScheme.primary),
      const SizedBox(width: 6),
      Text(title,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final isOwn = widget.profile.id == widget.currentUserId;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.profile.name,
            style: const TextStyle(fontWeight: FontWeight.bold)),
        centerTitle: true,
        actions: [
          if (widget.profile.isAdmin)
            IconButton(
              icon: const Icon(Icons.admin_panel_settings),
              tooltip: 'Admin Panel',
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) =>
                        AdminScreen(currentUser: widget.profile)),
              ),
            ),
          if (isOwn)
            IconButton(
              icon: const Icon(Icons.settings_outlined),
              tooltip: 'Settings',
              onPressed: () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => SettingsScreen(profile: widget.profile),
                  ),
                );
                setState(() {});
                widget.onChanged();
              },
            ),
        ],
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'Dashboard'),
            Tab(text: 'Lifts'),
            Tab(text: 'Workouts'),
            Tab(text: 'Community'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [_buildDashboardTab(), _buildLiftsTab(), _buildProgramTab(), _buildCommunityTab()],
      ),
      floatingActionButton: isOwn && _tabController.index == 1
          ? FloatingActionButton.extended(
              onPressed: _addLift,
              icon: const Icon(Icons.add),
              label: const Text('Add Lift'),
            )
          : null,
    );
  }

  static const _quotes = [
    '"The only bad workout is the one that didn\'t happen."',
    '"Strength does not come from the body. It comes from the will of the soul."',
    '"Push yourself because no one else is going to do it for you."',
    '"Every rep, every set, every step counts."',
    '"Your body can stand almost anything. It\'s your mind you have to convince."',
    '"You don\'t have to be great to start, but you have to start to be great."',
    '"Train insane or remain the same."',
    '"The pain you feel today will be the strength you feel tomorrow."',
    '"Results happen over time, not overnight. Work hard, stay consistent."',
    '"Don\'t limit your challenges. Challenge your limits."',
  ];

  Future<void> _pickPhoto() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    var bytes = result.files.first.bytes;
    if (bytes == null) return;

    // Auto-compress if over 700 KB
    if (bytes.lengthInBytes > 700 * 1024) {
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return;
      // Scale down so the longest side is at most 512 px
      final resized = decoded.width >= decoded.height
          ? img.copyResize(decoded, width: 512)
          : img.copyResize(decoded, height: 512);
      // Re-encode as JPEG, reducing quality until under 700 KB
      int quality = 85;
      var compressed = img.encodeJpg(resized, quality: quality);
      while (compressed.length > 700 * 1024 && quality > 30) {
        quality -= 10;
        compressed = img.encodeJpg(resized, quality: quality);
      }
      bytes = compressed;
    }

    final dataUrl = 'data:image/jpeg;base64,${base64Encode(bytes)}';
    setState(() => widget.profile.photoData = dataUrl);
    widget.onChanged();
  }

  void _addGoal() {
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Add Goal'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(hintText: 'e.g. Squat 315 lbs'),
          onSubmitted: (_) => _confirmGoal(ctrl.text),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () => _confirmGoal(ctrl.text),
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }

  void _confirmGoal(String text) {
    text = text.trim();
    if (text.isEmpty) return;
    Navigator.pop(context);
    setState(() => widget.profile.goals.add(text));
    widget.onChanged();
  }

  void _removeGoal(int index) {
    setState(() => widget.profile.goals.removeAt(index));
    widget.onChanged();
  }

  Widget _buildOtherProfileDashboard() {
    final photoData = widget.profile.photoData;

    final liftsWithDate = widget.profile.lifts.map((l) {
      DateTime? latest;
      for (final r in l.bests.values) {
        if (latest == null || r.date.isAfter(latest)) latest = r.date;
      }
      return (lift: l, date: latest);
    }).toList()
      ..sort((a, b) {
        if (a.date == null && b.date == null) return 0;
        if (a.date == null) return 1;
        if (b.date == null) return -1;
        return b.date!.compareTo(a.date!);
      });

    final sortedWorkouts = [...widget.profile.workouts]
      ..sort((a, b) => b.date.compareTo(a.date));

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 32, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                CircleAvatar(
                  radius: 28,
                  backgroundColor:
                      Theme.of(context).colorScheme.primaryContainer,
                  backgroundImage:
                      photoData != null ? NetworkImage(photoData) : null,
                  child: photoData == null
                      ? Text(
                          _initials(widget.profile.name),
                          style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onPrimaryContainer),
                        )
                      : null,
                ),
                const SizedBox(width: 14),
                Text(widget.profile.name,
                    style: const TextStyle(
                        fontSize: 28, fontWeight: FontWeight.bold)),
              ],
            ),
          ),
          const SizedBox(height: 28),
          _sectionHeader('Recent Lifts', Icons.fitness_center),
          const SizedBox(height: 8),
          if (liftsWithDate.isEmpty)
            const Padding(
              padding: EdgeInsets.only(bottom: 16),
              child: Text('No lifts logged yet.',
                  style: TextStyle(color: Colors.white54)),
            )
          else
            ...liftsWithDate.take(5).map((item) {
              final lift = item.lift;
              return Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  title: Row(children: [
                    Expanded(
                        child: Text(lift.name,
                            style: const TextStyle(
                                fontWeight: FontWeight.w600, fontSize: 15))),
                    _reactionSummary(lift.reactions),
                  ]),
                  subtitle: Text(_subtitle(lift),
                      style: const TextStyle(
                          fontSize: 12, color: Colors.white60)),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () async {
                    await Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => LiftDetailScreen(
                          lift: lift,
                          currentUserName: widget.currentUserName,
                          isOwnProfile: false,
                          onChanged: () {
                            setState(() {});
                            widget.onChanged();
                          },
                        ),
                      ),
                    );
                  },
                ),
              );
            }),
          const SizedBox(height: 8),
          _sectionHeader('Recent Workouts', Icons.calendar_today_outlined),
          const SizedBox(height: 8),
          if (sortedWorkouts.isEmpty)
            const Padding(
              padding: EdgeInsets.only(bottom: 16),
              child: Text('No workouts logged yet.',
                  style: TextStyle(color: Colors.white54)),
            )
          else
            ...sortedWorkouts.take(5).map((workout) {
              final exerciseNames =
                  workout.exercises.map((e) => e.liftName).join(' · ');
              return Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  title: Row(children: [
                    Text(_fmtDate(workout.date),
                        style: const TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 15)),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(workout.type.label,
                          style: TextStyle(
                              fontSize: 10,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onPrimaryContainer)),
                    ),
                    const Spacer(),
                    _reactionSummary(workout.reactions),
                  ]),
                  subtitle: Text(
                      exerciseNames.isEmpty ? 'No exercises' : exerciseNames,
                      style: const TextStyle(
                          fontSize: 12, color: Colors.white60),
                      overflow: TextOverflow.ellipsis),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => WorkoutDetailScreen(
                        workout: workout,
                        profile: widget.profile,
                        currentUserName: widget.currentUserName,
                        isOwnProfile: false,
                        onChanged: widget.onChanged,
                      ),
                    ),
                  ),
                ),
              );
            }),
          const SizedBox(height: 8),
          _sectionHeader('Goals', Icons.flag_outlined),
          const SizedBox(height: 8),
          if (widget.profile.goals.isEmpty)
            const Text('No goals set.',
                style: TextStyle(color: Colors.white54))
          else
            ...widget.profile.goals.map((goal) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(children: [
                    const Text('• ', style: TextStyle(color: Colors.white70)),
                    Expanded(
                        child: Text(goal,
                            style: const TextStyle(
                                fontSize: 14, color: Colors.white70))),
                  ]),
                )),
        ],
      ),
    );
  }

  Widget _buildDashboardTab() {
    final isOwn = widget.profile.id == widget.currentUserId;
    if (!isOwn) return _buildOtherProfileDashboard();

    final hour = DateTime.now().hour;
    final greeting = hour < 12
        ? 'Good morning'
        : hour < 17
            ? 'Good afternoon'
            : 'Good evening';

    final dayOfYear =
        DateTime.now().difference(DateTime(DateTime.now().year, 1, 1)).inDays;
    final quote = _quotes[dayOfYear % _quotes.length];

    RepRecord? mostRecent;
    String? mostRecentName;
    int? mostRecentReps;
    for (final lift in widget.profile.lifts) {
      for (final entry in lift.bests.entries) {
        if (mostRecent == null || entry.value.date.isAfter(mostRecent.date)) {
          mostRecent = entry.value;
          mostRecentName = lift.name;
          mostRecentReps = entry.key;
        }
      }
    }

    final photoData = widget.profile.photoData;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 32, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Greeting
          Text(
            '$greeting,',
            style: const TextStyle(fontSize: 16, color: Colors.white60),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          // Photo + Name row
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              GestureDetector(
                onTap: _pickPhoto,
                child: Stack(
                  alignment: Alignment.bottomRight,
                  children: [
                    CircleAvatar(
                      radius: 28,
                      backgroundColor:
                          Theme.of(context).colorScheme.primaryContainer,
                      backgroundImage: photoData != null
                          ? NetworkImage(photoData)
                          : null,
                      child: photoData == null
                          ? Text(
                              _initials(widget.profile.name),
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onPrimaryContainer,
                              ),
                            )
                          : null,
                    ),
                    CircleAvatar(
                      radius: 10,
                      backgroundColor:
                          Theme.of(context).colorScheme.surface,
                      child: Icon(Icons.camera_alt,
                          size: 12,
                          color: Theme.of(context).colorScheme.primary),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 14),
              Text(
                widget.profile.name,
                style: const TextStyle(
                    fontSize: 30, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 14),
          // Quote
          Text(
            quote,
            style: const TextStyle(
                fontSize: 14,
                color: Colors.white54,
                fontStyle: FontStyle.italic),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),
          const _WeightCalculatorCard(),
          const SizedBox(height: 20),
          // Equal-height cards
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Most Recent Lift
                Expanded(
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            Icon(Icons.fitness_center,
                                size: 16,
                                color: Theme.of(context).colorScheme.primary),
                            const SizedBox(width: 6),
                            const Text('Recent Lift',
                                style: TextStyle(
                                    fontSize: 12, color: Colors.white54)),
                          ]),
                          const SizedBox(height: 12),
                          if (mostRecent == null)
                            const Text('No lifts logged yet.',
                                style: TextStyle(
                                    fontSize: 13, color: Colors.white54))
                          else ...[
                            Text(mostRecentName!,
                                style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold),
                                overflow: TextOverflow.ellipsis),
                            const SizedBox(height: 4),
                            Text(
                              () {
                                final w = mostRecent!.weight % 1 == 0
                                    ? mostRecent.weight.toInt().toString()
                                    : mostRecent.weight.toStringAsFixed(1);
                                return '${mostRecentReps}RM  ·  $w ${mostRecent.unit}';
                              }(),
                              style: TextStyle(
                                  fontSize: 14,
                                  color:
                                      Theme.of(context).colorScheme.primary),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              _fmtDate(mostRecent.date),
                              style: const TextStyle(
                                  fontSize: 12, color: Colors.white38),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                // Goals
                Expanded(
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.flag_outlined,
                                  size: 16,
                                  color:
                                      Theme.of(context).colorScheme.primary),
                              const SizedBox(width: 6),
                              const Expanded(
                                child: Text('Goals',
                                    style: TextStyle(
                                        fontSize: 12,
                                        color: Colors.white54)),
                              ),
                              GestureDetector(
                                onTap: _addGoal,
                                child: Icon(Icons.add_circle_outline,
                                    size: 18,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .primary),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          if (widget.profile.goals.isEmpty)
                            const Text('No goals set.\nTap + to add one.',
                                style: TextStyle(
                                    fontSize: 13, color: Colors.white54))
                          else
                            ...widget.profile.goals.asMap().entries.map(
                                  (e) => Padding(
                                    padding: const EdgeInsets.only(bottom: 8),
                                    child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        const Text('• ',
                                            style: TextStyle(
                                                color: Colors.white70)),
                                        Expanded(
                                          child: Text(e.value,
                                              style: const TextStyle(
                                                  fontSize: 13,
                                                  color: Colors.white70)),
                                        ),
                                        GestureDetector(
                                          onTap: () => _removeGoal(e.key),
                                          child: const Icon(Icons.close,
                                              size: 14,
                                              color: Colors.white38),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          StreamBuilder<List<Profile>>(
            stream: LiftStore.stream(),
            builder: (context, snap) {
              final all = snap.data ?? [];
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _sectionHeader('Community Feed', Icons.dynamic_feed_outlined),
                  const SizedBox(height: 8),
                  _buildFeed(all),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildLiftsTab() {
    final isOwn = widget.profile.id == widget.currentUserId;
    if (lifts.isEmpty) {
      return const Center(
        child: Text(
          'No lifts yet.\nTap + to add your first lift.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 16, color: Colors.white54),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: lifts.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        final lift = lifts[i];
        final card = Card(
          margin: EdgeInsets.zero,
          child: ListTile(
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            title: Text(lift.name,
                style: const TextStyle(
                    fontSize: 18, fontWeight: FontWeight.w600)),
            subtitle: Text(_subtitle(lift),
                style:
                    const TextStyle(fontSize: 13, color: Colors.white60)),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _reactionSummary(lift.reactions),
                const SizedBox(width: 4),
                const Icon(Icons.chevron_right),
              ],
            ),
            onTap: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => LiftDetailScreen(
                    lift: lift,
                    currentUserName: widget.currentUserName,
                    isOwnProfile: isOwn,
                    onChanged: () {
                      setState(() {});
                      widget.onChanged();
                    },
                  ),
                ),
              );
            },
          ),
        );
        if (!isOwn) return card;
        return Dismissible(
          key: ValueKey('lift-$i'),
          direction: DismissDirection.endToStart,
          background: Container(
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: 20),
            decoration: BoxDecoration(
              color: Colors.red.shade800,
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.delete_outline, color: Colors.white),
          ),
          confirmDismiss: (_) async {
            _deleteLift(i);
            return false;
          },
          child: card,
        );
      },
    );
  }


  String _timeAgo(DateTime d) {
    final diff = DateTime.now().difference(d);
    if (diff.inDays >= 1) return '${diff.inDays}d ago';
    if (diff.inHours >= 1) return '${diff.inHours}h ago';
    if (diff.inMinutes >= 1) return '${diff.inMinutes}m ago';
    return 'just now';
  }

  Widget _buildFeed(List<Profile> allProfiles) {
    final others = allProfiles
        .where((p) => p.id != widget.currentUserId)
        .toList();

    final items = <({Profile profile, DateTime date, bool isLift, Lift? lift, RepRecord? record, Workout? workout})>[];
    for (final p in others) {
      for (final lift in p.lifts) {
        for (final record in lift.history) {
          items.add((profile: p, date: record.date, isLift: true,
              lift: lift, record: record, workout: null));
        }
      }
      for (final workout in p.workouts) {
        items.add((profile: p, date: workout.date, isLift: false,
            lift: null, record: null, workout: workout));
      }
    }
    items.sort((a, b) => b.date.compareTo(a.date));
    final recent = items.take(15).toList();

    if (recent.isEmpty) {
      return const Padding(
        padding: EdgeInsets.only(top: 4, bottom: 8),
        child: Text('No recent activity from others yet.',
            style: TextStyle(color: Colors.white54, fontSize: 13)),
      );
    }

    return Column(
      children: recent.map((item) {
        final photoData = item.profile.photoData;
        String description;
        VoidCallback onTap;

        if (item.isLift) {
          final w = item.record!.weight % 1 == 0
              ? item.record!.weight.toInt().toString()
              : item.record!.weight.toStringAsFixed(1);
          description =
              'logged $w ${item.record!.unit} ${item.record!.reps}RM — ${item.lift!.name}';
          onTap = () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => LiftDetailScreen(
                    lift: item.lift!,
                    currentUserName: widget.currentUserName,
                    isOwnProfile: false,
                    onChanged: () => LiftStore.saveProfile(item.profile),
                  ),
                ),
              );
        } else {
          final exNames = item.workout!.exercises
              .map((e) => e.liftName)
              .join(', ');
          description =
              'completed a ${item.workout!.type.label} workout${exNames.isNotEmpty ? ' · $exNames' : ''}';
          onTap = () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => WorkoutDetailScreen(
                    workout: item.workout!,
                    profile: item.profile,
                    currentUserName: widget.currentUserName,
                    isOwnProfile: false,
                    onChanged: () => LiftStore.saveProfile(item.profile),
                  ),
                ),
              );
        }

        return InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  radius: 18,
                  backgroundColor:
                      Theme.of(context).colorScheme.primaryContainer,
                  backgroundImage:
                      photoData != null ? NetworkImage(photoData) : null,
                  child: photoData == null
                      ? Text(_initials(item.profile.name),
                          style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onPrimaryContainer))
                      : null,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      RichText(
                        text: TextSpan(children: [
                          TextSpan(
                              text: item.profile.name,
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white,
                                  fontSize: 13)),
                          TextSpan(
                              text: ' $description',
                              style: const TextStyle(
                                  color: Colors.white70, fontSize: 13)),
                        ]),
                      ),
                      const SizedBox(height: 2),
                      Text(_timeAgo(item.date),
                          style: const TextStyle(
                              fontSize: 11, color: Colors.white38)),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right,
                    size: 16, color: Colors.white38),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildProgramTab() {
    return _ProgramTabView(
      profile: widget.profile,
      onChanged: widget.onChanged,
      onAddWorkout: _logWorkout,
      currentUserName: widget.currentUserName,
    );
  }

  Widget _buildCommunityTab() {
    return StreamBuilder<List<Profile>>(
      stream: LiftStore.stream(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        final profiles = (snap.data ?? [])
            .where((p) => p.id != widget.profile.id)
            .toList();

        if (profiles.isEmpty) {
          return const Center(
            child: Text('No other profiles yet.',
                style: TextStyle(color: Colors.white54)),
          );
        }

        return ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: profiles.length,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemBuilder: (_, i) {
            final p = profiles[i];
            final photoData = p.photoData;
            return Card(
              margin: EdgeInsets.zero,
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 8),
                leading: CircleAvatar(
                  radius: 24,
                  backgroundColor:
                      Theme.of(context).colorScheme.primaryContainer,
                  backgroundImage:
                      photoData != null ? NetworkImage(photoData) : null,
                  child: photoData == null
                      ? Text(_initials(p.name),
                          style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onPrimaryContainer))
                      : null,
                ),
                title: Text(p.name,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 16)),
                subtitle: Text(
                  '${p.lifts.length} lift${p.lifts.length == 1 ? '' : 's'} · ${p.workouts.length} workout${p.workouts.length == 1 ? '' : 's'}',
                  style:
                      const TextStyle(fontSize: 12, color: Colors.white54),
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => HomeScreen(
                      profile: p,
                      currentUserId: widget.currentUserId,
                      currentUserName: widget.currentUserName,
                      onChanged: () => LiftStore.saveProfile(p),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

// ─── Lift Detail Screen ───────────────────────────────────────────────────────

class LiftDetailScreen extends StatefulWidget {
  final Lift lift;
  final String currentUserName;
  final bool isOwnProfile;
  final VoidCallback onChanged;

  const LiftDetailScreen({
    super.key,
    required this.lift,
    required this.currentUserName,
    required this.isOwnProfile,
    required this.onChanged,
  });

  @override
  State<LiftDetailScreen> createState() => _LiftDetailScreenState();
}

class _LiftDetailScreenState extends State<LiftDetailScreen> {
  static const repOptions = [1, 2, 3, 4, 5, 6, 8, 10, 12, 15, 20];
  DateTime _selectedDate = DateTime.now();
  final _commentCtrl = TextEditingController();

  @override
  void dispose() {
    _commentCtrl.dispose();
    super.dispose();
  }

  void _addComment() {
    final text = _commentCtrl.text.trim();
    if (text.isEmpty) return;
    setState(() {
      widget.lift.comments.add(Comment(
        author: widget.currentUserName,
        text: text,
        date: DateTime.now(),
      ));
      _commentCtrl.clear();
    });
    widget.onChanged();
  }

  void _deleteComment(int index) {
    setState(() => widget.lift.comments.removeAt(index));
    widget.onChanged();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
    );
    if (picked != null) setState(() => _selectedDate = picked);
  }

  void _addOrEditRecord({RepRecord? existing, int? existingIndex}) {
    int selectedReps = existing?.reps ?? 1;
    final weightController = TextEditingController(
      text: existing != null
          ? (existing.weight % 1 == 0
              ? existing.weight.toInt().toString()
              : existing.weight.toStringAsFixed(1))
          : '',
    );
    String unit = existing?.unit ?? 'lbs';
    DateTime selectedDate = existing?.date ?? _selectedDate;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => Padding(
          padding: EdgeInsets.fromLTRB(
              24, 24, 24, MediaQuery.of(ctx).viewInsets.bottom + 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                existing != null ? 'Edit Record' : 'Log New Record',
                style:
                    const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                icon: const Icon(Icons.calendar_today_outlined, size: 16),
                label: Text(_formatDate(selectedDate)),
                onPressed: () async {
                  final picked = await showDatePicker(
                    context: ctx,
                    initialDate: selectedDate,
                    firstDate: DateTime(2000),
                    lastDate: DateTime.now(),
                  );
                  if (picked != null) setModalState(() => selectedDate = picked);
                },
              ),
              const SizedBox(height: 16),
              const Text('Reps',
                  style: TextStyle(color: Colors.white60, fontSize: 13)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: repOptions.map((r) {
                  final selected = r == selectedReps;
                  return GestureDetector(
                    onTap: () => setModalState(() => selectedReps = r),
                    child: Container(
                      width: 52,
                      height: 44,
                      decoration: BoxDecoration(
                        color: selected
                            ? Theme.of(context).colorScheme.primary
                            : Colors.white12,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        '${r}RM',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: selected ? Colors.white : Colors.white70,
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 20),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: weightController,
                      autofocus: existing == null,
                      keyboardType: const TextInputType.numberWithOptions(
                          decimal: true),
                      decoration: const InputDecoration(
                        labelText: 'Weight',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'lbs', label: Text('lbs')),
                      ButtonSegment(value: 'kg', label: Text('kg')),
                    ],
                    selected: {unit},
                    onSelectionChanged: (s) =>
                        setModalState(() => unit = s.first),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: () {
                  final w = double.tryParse(weightController.text.trim());
                  if (w == null || w <= 0) return;
                  Navigator.pop(ctx);
                  setState(() {
                    _selectedDate = selectedDate;
                    final record = RepRecord(
                      reps: selectedReps,
                      weight: w,
                      unit: unit,
                      date: selectedDate,
                    );
                    if (existingIndex != null) {
                      widget.lift.history[existingIndex] = record;
                    } else {
                      widget.lift.history.add(record);
                    }
                    widget.lift.recomputeBests();
                  });
                  widget.onChanged();
                },
                child: const Text('Save', style: TextStyle(fontSize: 16)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _deleteRecord(int historyIndex) {
    setState(() {
      widget.lift.history.removeAt(historyIndex);
      widget.lift.recomputeBests();
    });
    widget.onChanged();
  }

  Widget _buildOneRMCard() {
    final oneRM = widget.lift.bests[1];
    if (oneRM == null) return const SizedBox.shrink();
    final w = oneRM.weight % 1 == 0
        ? oneRM.weight.toInt().toString()
        : oneRM.weight.toStringAsFixed(1);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      color: Theme.of(context).colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          children: [
            const Icon(Icons.emoji_events, size: 32, color: Colors.amber),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Most Recent 1RM',
                    style: TextStyle(fontSize: 13, color: Colors.white70)),
                Text('$w ${oneRM.unit}',
                    style: const TextStyle(
                        fontSize: 28, fontWeight: FontWeight.bold)),
              ],
            ),
            const Spacer(),
            Text(_formatDate(oneRM.date),
                style: const TextStyle(fontSize: 12, color: Colors.white60)),
          ],
        ),
      ),
    );
  }

  Widget _buildChart() {
    if (widget.lift.history.isEmpty) return const SizedBox.shrink();

    // Build spots from all records sorted by date
    final records = [...widget.lift.history]
      ..sort((a, b) => a.date.compareTo(b.date));

    final spots = records.map((r) {
      final daysSinceEpoch = r.date.millisecondsSinceEpoch / 86400000.0;
      return FlSpot(daysSinceEpoch, r.weight);
    }).toList();

    final minY = records.map((r) => r.weight).reduce(min);
    final maxY = records.map((r) => r.weight).reduce(max);
    final yPadding = max((maxY - minY) * 0.15, 10.0);

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 16, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(left: 12, bottom: 12),
              child: Text('Weight Progress',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600,
                      color: Colors.white70)),
            ),
            SizedBox(
              height: 200,
              child: LineChart(
                LineChartData(
                  minY: minY - yPadding,
                  maxY: maxY + yPadding,
                  gridData: FlGridData(
                    show: true,
                    drawVerticalLine: false,
                    getDrawingHorizontalLine: (_) => FlLine(
                      color: Colors.white12,
                      strokeWidth: 1,
                    ),
                  ),
                  borderData: FlBorderData(show: false),
                  titlesData: FlTitlesData(
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 44,
                        getTitlesWidget: (value, meta) => Text(
                          value.toInt().toString(),
                          style: const TextStyle(
                              fontSize: 11, color: Colors.white54),
                        ),
                      ),
                    ),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 28,
                        interval: spots.length > 1
                            ? (spots.last.x - spots.first.x) /
                                (spots.length > 4 ? 3 : spots.length - 1)
                            : 1,
                        getTitlesWidget: (value, meta) {
                          final date = DateTime.fromMillisecondsSinceEpoch(
                              (value * 86400000).toInt());
                          const months = [
                            'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
                            'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
                          ];
                          return Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              '${months[date.month - 1]} ${date.day}',
                              style: const TextStyle(
                                  fontSize: 10, color: Colors.white54),
                            ),
                          );
                        },
                      ),
                    ),
                    rightTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false)),
                    topTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false)),
                  ),
                  lineBarsData: [
                    LineChartBarData(
                      spots: spots,
                      isCurved: true,
                      curveSmoothness: 0.3,
                      color: Theme.of(context).colorScheme.primary,
                      barWidth: 2.5,
                      dotData: FlDotData(
                        show: true,
                        getDotPainter: (spot, percent, bar, index) =>
                            FlDotCirclePainter(
                          radius: 4,
                          color: Theme.of(context).colorScheme.primary,
                          strokeWidth: 2,
                          strokeColor: Colors.white,
                        ),
                      ),
                      belowBarData: BarAreaData(
                        show: true,
                        color: Theme.of(context)
                            .colorScheme
                            .primary
                            .withValues(alpha: 0.15),
                      ),
                    ),
                  ],
                  lineTouchData: LineTouchData(
                    touchTooltipData: LineTouchTooltipData(
                      getTooltipItems: (touchedSpots) =>
                          touchedSpots.map((s) {
                        final date = DateTime.fromMillisecondsSinceEpoch(
                            (s.x * 86400000).toInt());
                        final rec = records.firstWhere(
                            (r) => r.date.day == date.day &&
                                r.date.month == date.month &&
                                r.date.year == date.year,
                            orElse: () => records[s.spotIndex]);
                        final w = rec.weight % 1 == 0
                            ? rec.weight.toInt().toString()
                            : rec.weight.toStringAsFixed(1);
                        return LineTooltipItem(
                          '$w ${rec.unit}\n${rec.reps}RM\n${_formatDate(date)}',
                          const TextStyle(
                              fontSize: 12,
                              color: Colors.white,
                              fontWeight: FontWeight.w500),
                        );
                      }).toList(),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDate(DateTime d) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    return '${months[d.month - 1]} ${d.day}, ${d.year}';
  }

  @override
  Widget build(BuildContext context) {
    // Pair each history record with its original index so edits/deletes work.
    final sorted = widget.lift.history
        .asMap()
        .entries
        .toList()
      ..sort((a, b) => b.value.date.compareTo(a.value.date));

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.lift.name,
            style: const TextStyle(fontWeight: FontWeight.bold)),
        centerTitle: true,
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.calendar_today_outlined, size: 16),
            label: Text(_formatDate(_selectedDate)),
            onPressed: _pickDate,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              children: [
                _buildOneRMCard(),
                _buildChart(),
                if (sorted.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 32),
                    child: Text(
                      'No records yet.\nTap + to log a lift.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 16, color: Colors.white54),
                    ),
                  )
                else
                  ...sorted.map((entry) {
                    final historyIndex = entry.key;
                    final rec = entry.value;
                    final isBest = widget.lift.bests[rec.reps] == rec;
                    final w = rec.weight % 1 == 0
                        ? rec.weight.toInt().toString()
                        : rec.weight.toStringAsFixed(1);
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Card(
                        margin: EdgeInsets.zero,
                        child: ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 20, vertical: 10),
                          leading: Container(
                            width: 52,
                            height: 52,
                            decoration: BoxDecoration(
                              color: Theme.of(context)
                                  .colorScheme
                                  .primaryContainer,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              '${rec.reps}RM',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 15,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onPrimaryContainer,
                              ),
                            ),
                          ),
                          title: Row(children: [
                            Text('$w ${rec.unit}',
                                style: const TextStyle(
                                    fontSize: 22,
                                    fontWeight: FontWeight.bold)),
                            if (isBest) ...[
                              const SizedBox(width: 6),
                              const Icon(Icons.star,
                                  size: 14, color: Colors.amber),
                            ],
                          ]),
                          subtitle: Text(_formatDate(rec.date),
                              style: const TextStyle(
                                  fontSize: 12, color: Colors.white54)),
                          trailing: widget.isOwnProfile
                              ? Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      icon: const Icon(Icons.edit_outlined),
                                      onPressed: () => _addOrEditRecord(
                                          existing: rec,
                                          existingIndex: historyIndex),
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.delete_outline,
                                          color: Colors.redAccent),
                                      onPressed: () =>
                                          _deleteRecord(historyIndex),
                                    ),
                                  ],
                                )
                              : null,
                        ),
                      ),
                    );
                  }),
                _SocialSection(
                  currentUserName: widget.currentUserName,
                  reactions: widget.lift.reactions,
                  comments: widget.lift.comments,
                  onChanged: widget.onChanged,
                  onDeleteComment: _deleteComment,
                  isOwnProfile: widget.isOwnProfile,
                ),
              ],
            ),
          ),
          if (!widget.isOwnProfile)
            _CommentInputBar(
              controller: _commentCtrl,
              onSubmit: _addComment,
            ),
        ],
      ),
      floatingActionButton: widget.isOwnProfile
          ? FloatingActionButton.extended(
              onPressed: () => _addOrEditRecord(),
              icon: const Icon(Icons.add),
              label: const Text('Log Record'),
            )
          : null,
    );
  }
}

// ─── Workout Screen ───────────────────────────────────────────────────────────

enum SetStatus { none, missed, succeeded }

class _SetRow {
  final TextEditingController reps;
  final TextEditingController weight;
  SetStatus status = SetStatus.none;
  _SetRow({String reps = '5', String weight = ''})
      : reps = TextEditingController(text: reps),
        weight = TextEditingController(text: weight);
  void dispose() {
    reps.dispose();
    weight.dispose();
  }
}

class WorkoutScreen extends StatefulWidget {
  final Profile profile;
  final VoidCallback onSaved;

  const WorkoutScreen(
      {super.key, required this.profile, required this.onSaved});

  @override
  State<WorkoutScreen> createState() => _WorkoutScreenState();
}

class _WorkoutScreenState extends State<WorkoutScreen> {
  DateTime _date = DateTime.now();
  WorkoutType _type = WorkoutType.strength;
  final _timeCtrl = TextEditingController();
  final _resultCtrl = TextEditingController();
  final List<WorkoutExercise> _exercises = [];
  final Map<String, TextEditingController> _repsCtrl = {};
  final Map<String, TextEditingController> _weightCtrl = {};
  final Map<String, List<_SetRow>> _setCtrl = {};
  final Map<String, String> _unitSel = {};
  final Map<String, FixedExtentScrollController> _otherScrollCtrl = {};
  final Map<String, TextEditingController> _otherValueCtrl = {};
static const _otherOptions = ['Reps', 'Weight', 'Height', 'RPE'];

  @override
  void dispose() {
    _timeCtrl.dispose();
    _resultCtrl.dispose();
    for (final c in _repsCtrl.values) { c.dispose(); }
    for (final c in _weightCtrl.values) { c.dispose(); }
    for (final rows in _setCtrl.values) {
      for (final r in rows) { r.dispose(); }
    }
    for (final c in _otherScrollCtrl.values) { c.dispose(); }
    for (final c in _otherValueCtrl.values) { c.dispose(); }
    super.dispose();
  }

  String _fmt(DateTime d) {
    const m = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    return '${m[d.month - 1]} ${d.day}, ${d.year}';
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
    );
    if (picked != null) setState(() => _date = picked);
  }

  void _addExercise(String name) {
    if (_exercises.any((e) => e.liftName == name)) return;
    setState(() {
      _exercises.add(WorkoutExercise(liftName: name));
      _repsCtrl[name] = TextEditingController(text: '10');
      _weightCtrl[name] = TextEditingController();
      _unitSel[name] = 'lbs';
      _otherScrollCtrl[name] = FixedExtentScrollController();
      _otherValueCtrl[name] = TextEditingController();
      _setCtrl[name] = [_SetRow(), _SetRow(), _SetRow()];
    });
  }

  void _removeExercise(int i) {
    final name = _exercises[i].liftName;
    setState(() {
      _exercises.removeAt(i);
      _repsCtrl.remove(name)?.dispose();
      _weightCtrl.remove(name)?.dispose();
      _unitSel.remove(name);
      _otherScrollCtrl.remove(name)?.dispose();
      _otherValueCtrl.remove(name)?.dispose();
      for (final r in _setCtrl.remove(name) ?? []) { r.dispose(); }
    });
  }

  void _openExercisePicker() {
    final already = _exercises.map((e) => e.liftName).toSet();
    showDialog(
      context: context,
      builder: (_) => _ExercisePickerDialog(
        existingLifts: widget.profile.lifts,
        alreadyAdded: already,
        onConfirm: (names, newNames) {
          for (final name in newNames) {
            widget.profile.lifts.add(Lift(name: name));
          }
          if (newNames.isNotEmpty) widget.onSaved();
          for (final name in names) {
            _addExercise(name);
          }
        },
      ),
    );
  }

  void _save() {
    for (final ex in _exercises) {
      if (_type == WorkoutType.strength) {
        final unit = _unitSel[ex.liftName] ?? 'lbs';
        ex.sets = (_setCtrl[ex.liftName] ?? [])
            .where((r) => r.weight.text.trim().isNotEmpty)
            .map((r) => WorkoutSet(
                  reps: int.tryParse(r.reps.text.trim()) ?? 5,
                  weight: double.tryParse(r.weight.text.trim()) ?? 0,
                  unit: unit,
                ))
            .toList();
      } else {
        ex.reps = int.tryParse(_repsCtrl[ex.liftName]?.text ?? '') ?? ex.reps;
        ex.weight =
            double.tryParse(_weightCtrl[ex.liftName]?.text.trim() ?? '');
        ex.unit = _unitSel[ex.liftName] ?? 'lbs';
        final otherIdx = _otherScrollCtrl[ex.liftName]?.selectedItem ?? 0;
        final otherVal = _otherValueCtrl[ex.liftName]?.text.trim() ?? '';
        ex.otherType = _otherOptions[otherIdx];
        ex.otherValue = otherVal.isEmpty ? null : otherVal;
      }
    }
    widget.profile.workouts.add(Workout(
      date: _date,
      type: _type,
      timeCap: int.tryParse(_timeCtrl.text.trim()),
      result: _resultCtrl.text.trim().isEmpty ? null : _resultCtrl.text.trim(),
      exercises: _exercises,
    ));
    widget.onSaved();
    Navigator.pop(context);
  }

  String get _timeLabel => switch (_type) {
        WorkoutType.amrap => 'Time Cap (min)',
        WorkoutType.emom => 'Duration (min)',
        WorkoutType.forTime => 'Time to Complete (min)',
        _ => '',
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('New Workout',
            style: TextStyle(fontWeight: FontWeight.bold)),
        centerTitle: true,
        actions: [
          TextButton(
            onPressed: _exercises.isNotEmpty ? _save : null,
            child: const Text('Save', style: TextStyle(fontSize: 16)),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Date
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: OutlinedButton.icon(
              icon: const Icon(Icons.calendar_today_outlined, size: 18),
              label: Text(_fmt(_date)),
              onPressed: _pickDate,
              style: OutlinedButton.styleFrom(alignment: Alignment.centerLeft),
            ),
          ),
          // Workout type chips
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: WorkoutType.values.map((t) => Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(t.label),
                    selected: _type == t,
                    onSelected: (_) => setState(() => _type = t),
                  ),
                )).toList(),
              ),
            ),
          ),
          // Time field (functional workouts only)
          if (_type != WorkoutType.strength)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: TextField(
                controller: _timeCtrl,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: _timeLabel,
                  border: const OutlineInputBorder(),
                  suffixText: 'min',
                ),
              ),
            ),
          // Result field (functional workouts)
          if (_type != WorkoutType.strength)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: TextField(
                controller: _resultCtrl,
                decoration: InputDecoration(
                  labelText: switch (_type) {
                    WorkoutType.amrap => 'Rounds Completed',
                    WorkoutType.emom => 'Completed?',
                    WorkoutType.forTime => 'Completion Time',
                    _ => 'Result',
                  },
                  hintText: switch (_type) {
                    WorkoutType.amrap => 'e.g. 5 rounds + 3 reps',
                    WorkoutType.emom => 'e.g. Yes / 8 of 10 rounds',
                    WorkoutType.forTime => 'e.g. 12:34',
                    _ => '',
                  },
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
          // Exercise list
          Expanded(
            child: _exercises.isEmpty
                ? const Center(
                    child: Text(
                      'No exercises yet.\nTap + to add exercises.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 16, color: Colors.white54),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.all(16),
                    itemCount: _exercises.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 12),
                    itemBuilder: (_, i) => _type == WorkoutType.strength
                        ? _buildStrengthCard(_exercises[i], i)
                        : _buildFunctionalCard(_exercises[i], i),
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openExercisePicker,
        icon: const Icon(Icons.add),
        label: const Text('Add Exercise'),
      ),
    );
  }

  Widget _buildFunctionalCard(WorkoutExercise ex, int i) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(
                  child: Text(ex.liftName,
                      style: const TextStyle(
                          fontSize: 17, fontWeight: FontWeight.bold))),
              IconButton(
                icon: const Icon(Icons.close, size: 20),
                onPressed: () => _removeExercise(i),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
            ]),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                SizedBox(
                  width: 80,
                  child: TextField(
                    controller: _repsCtrl[ex.liftName],
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                        labelText: 'Reps', border: OutlineInputBorder()),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _weightCtrl[ex.liftName],
                    keyboardType: const TextInputType.numberWithOptions(
                        decimal: true),
                    decoration: const InputDecoration(
                        labelText: 'Weight', border: OutlineInputBorder()),
                  ),
                ),
                const SizedBox(width: 8),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'lbs', label: Text('lbs')),
                    ButtonSegment(value: 'kg', label: Text('kg')),
                  ],
                  selected: {_unitSel[ex.liftName] ?? 'lbs'},
                  onSelectionChanged: (s) =>
                      setState(() => _unitSel[ex.liftName] = s.first),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Text('Other',
                style: TextStyle(color: Colors.white60, fontSize: 13)),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Scroll wheel
                Container(
                  height: 100,
                  width: 100,
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.white24),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      ListWheelScrollView(
                        controller: _otherScrollCtrl[ex.liftName],
                        itemExtent: 32,
                        physics: const FixedExtentScrollPhysics(),
                        onSelectedItemChanged: (_) => setState(() {}),
                        children: _otherOptions
                            .map((o) => Center(
                                  child: Text(o,
                                      style:
                                          const TextStyle(fontSize: 14)),
                                ))
                            .toList(),
                      ),
                      // Selection highlight
                      IgnorePointer(
                        child: Container(
                          height: 32,
                          decoration: BoxDecoration(
                            border: Border(
                              top: BorderSide(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .primary,
                                  width: 1.5),
                              bottom: BorderSide(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .primary,
                                  width: 1.5),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _otherValueCtrl[ex.liftName],
                    keyboardType: const TextInputType.numberWithOptions(
                        decimal: true),
                    decoration: InputDecoration(
                      labelText: _otherOptions[
                          _otherScrollCtrl[ex.liftName]
                                  ?.selectedItem ??
                              0],
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStrengthCard(WorkoutExercise ex, int i) {
    final rows = _setCtrl[ex.liftName] ?? [];
    final unit = _unitSel[ex.liftName] ?? 'lbs';
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header: name + unit toggle + close
            Row(children: [
              Expanded(
                child: Text(ex.liftName,
                    style: const TextStyle(
                        fontSize: 17, fontWeight: FontWeight.bold)),
              ),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'lbs', label: Text('lbs')),
                  ButtonSegment(value: 'kg', label: Text('kg')),
                ],
                selected: {unit},
                onSelectionChanged: (s) =>
                    setState(() => _unitSel[ex.liftName] = s.first),
                style: ButtonStyle(
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: () => _removeExercise(i),
                child: const Icon(Icons.close,
                    size: 20, color: Colors.white54),
              ),
            ]),
            const SizedBox(height: 10),
            // Column headers
            const Row(children: [
              SizedBox(
                  width: 28,
                  child: Text('Set',
                      style:
                          TextStyle(fontSize: 11, color: Colors.white38))),
              SizedBox(width: 8),
              SizedBox(
                  width: 64,
                  child: Text('Reps',
                      style:
                          TextStyle(fontSize: 11, color: Colors.white38))),
              SizedBox(width: 8),
              Expanded(
                  child: Text('Weight',
                      style:
                          TextStyle(fontSize: 11, color: Colors.white38))),
              SizedBox(width: 84), // space for status buttons
            ]),
            const SizedBox(height: 6),
            // Set rows
            ...rows.asMap().entries.map((e) {
              final idx = e.key;
              final row = e.value;
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    SizedBox(
                      width: 28,
                      child: Text('${idx + 1}',
                          style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: Theme.of(context)
                                  .colorScheme
                                  .primary)),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 64,
                      child: TextField(
                        controller: row.reps,
                        keyboardType: TextInputType.number,
                        textAlign: TextAlign.center,
                        decoration: const InputDecoration(
                          isDense: true,
                          border: OutlineInputBorder(),
                          contentPadding: EdgeInsets.symmetric(
                              vertical: 8, horizontal: 6),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: row.weight,
                        keyboardType:
                            const TextInputType.numberWithOptions(
                                decimal: true),
                        textAlign: TextAlign.center,
                        decoration: const InputDecoration(
                          isDense: true,
                          border: OutlineInputBorder(),
                          contentPadding: EdgeInsets.symmetric(
                              vertical: 8, horizontal: 6),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // Miss button
                    GestureDetector(
                      onTap: () => setState(() {
                        row.status = row.status == SetStatus.missed
                            ? SetStatus.none
                            : SetStatus.missed;
                      }),
                      child: Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          color: row.status == SetStatus.missed
                              ? Colors.red
                              : Colors.white10,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Icon(Icons.close,
                            size: 18,
                            color: row.status == SetStatus.missed
                                ? Colors.white
                                : Colors.white38),
                      ),
                    ),
                    const SizedBox(width: 6),
                    // Success button
                    GestureDetector(
                      onTap: () => setState(() {
                        row.status = row.status == SetStatus.succeeded
                            ? SetStatus.none
                            : SetStatus.succeeded;
                      }),
                      child: Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          color: row.status == SetStatus.succeeded
                              ? Colors.green
                              : Colors.white10,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Icon(Icons.check,
                            size: 18,
                            color: row.status == SetStatus.succeeded
                                ? Colors.white
                                : Colors.white38),
                      ),
                    ),
                  ],
                ),
              );
            }),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  icon: const Icon(Icons.add_circle_outline, size: 22),
                  tooltip: 'Add set',
                  onPressed: () => setState(() {
                    final prev = rows.isNotEmpty ? rows.last : null;
                    rows.add(_SetRow(
                      reps: prev?.reps.text ?? '5',
                      weight: prev?.weight.text ?? '',
                    ));
                  }),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  visualDensity: VisualDensity.compact,
                ),
                const SizedBox(width: 16),
                IconButton(
                  icon: const Icon(Icons.remove_circle_outline, size: 22),
                  tooltip: 'Remove last set',
                  onPressed: rows.isEmpty
                      ? null
                      : () => setState(() => rows.removeLast()..dispose()),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Program Tab ─────────────────────────────────────────────────────────────

class _ProgramTabView extends StatefulWidget {
  final Profile profile;
  final VoidCallback onChanged;
  final VoidCallback onAddWorkout;
  final String currentUserName;
  const _ProgramTabView({
    required this.profile,
    required this.onChanged,
    required this.onAddWorkout,
    required this.currentUserName,
  });

  @override
  State<_ProgramTabView> createState() => _ProgramTabViewState();
}

class _ProgramTabViewState extends State<_ProgramTabView> {
  late DateTime _weekStart;
  late DateTime _selectedDay;

  static const _dayLabels = ['S', 'M', 'T', 'W', 'T', 'F', 'S'];
  static const _dayNames = ['Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday'];
  static const _months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];

  @override
  void initState() {
    super.initState();
    final today = _dateOnly(DateTime.now());
    final daysFromSunday = today.weekday % 7; // Mon=1%7=1 … Sun=7%7=0
    _weekStart = today.subtract(Duration(days: daysFromSunday));
    _selectedDay = today;
  }

  DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  ProgramDay? _dayData(DateTime date) {
    try {
      return widget.profile.program
          .firstWhere((d) => _sameDay(d.date, date));
    } catch (_) {
      return null;
    }
  }

  void _addExercises() async {
    final liftNames = widget.profile.lifts.map((l) => l.name).toList();
    final selected = <String>{};
    final customCtrl = TextEditingController();

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: const Text('Add Exercises'),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (liftNames.isNotEmpty) ...[
                  SizedBox(
                    height: 200,
                    child: ListView(
                      children: liftNames.map((name) => CheckboxListTile(
                        title: Text(name),
                        value: selected.contains(name),
                        onChanged: (v) => setDlg(() {
                          if (v == true) { selected.add(name); }
                          else { selected.remove(name); }
                        }),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                      )).toList(),
                    ),
                  ),
                  const Divider(),
                ],
                Row(children: [
                  Expanded(
                    child: TextField(
                      controller: customCtrl,
                      decoration: const InputDecoration(
                        hintText: 'Custom exercise…',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(Icons.add),
                    onPressed: () {
                      final t = customCtrl.text.trim();
                      if (t.isNotEmpty) {
                        setDlg(() => selected.add(t));
                        customCtrl.clear();
                      }
                    },
                  ),
                ]),
                if (selected.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 4,
                    children: selected.map((s) => Chip(
                      label: Text(s, style: const TextStyle(fontSize: 12)),
                      onDeleted: () => setDlg(() => selected.remove(s)),
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    )).toList(),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              onPressed: selected.isEmpty ? null : () {
                Navigator.pop(ctx);
                _addExercisesToDay(selected.toList());
              },
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
    customCtrl.dispose();
  }

  void _addExercisesToDay(List<String> names) {
    setState(() {
      var day = _dayData(_selectedDay);
      if (day == null) {
        day = ProgramDay(date: _selectedDay);
        widget.profile.program.add(day);
      }
      for (final name in names) {
        day.exercises.add(ProgramExercise(
          name: name,
          sets: [ProgramSet(), ProgramSet(), ProgramSet()],
        ));
      }
    });
    widget.onChanged();
  }


  String _weekRangeLabel() {
    final end = _weekStart.add(const Duration(days: 6));
    if (_weekStart.month == end.month) {
      return '${_months[_weekStart.month - 1]} ${_weekStart.day} – ${end.day}, ${end.year}';
    }
    return '${_months[_weekStart.month - 1]} ${_weekStart.day} – ${_months[end.month - 1]} ${end.day}, ${end.year}';
  }

  String _selectedDayLabel() {
    final dow = _selectedDay.weekday % 7;
    return '${_dayNames[dow]}, ${_months[_selectedDay.month - 1]} ${_selectedDay.day}';
  }

  String _fmtDate(DateTime d) {
    const m = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${m[d.month - 1]} ${d.day}, ${d.year}';
  }

  Widget _dismissBackground() => Container(
    alignment: Alignment.centerRight,
    padding: const EdgeInsets.only(right: 20),
    decoration: BoxDecoration(
      color: Colors.red,
      borderRadius: BorderRadius.circular(12),
    ),
    child: const Icon(Icons.delete_outline, color: Colors.white),
  );

  @override
  Widget build(BuildContext context) {
    final dayData = _dayData(_selectedDay);
    final exercises = dayData?.exercises ?? [];
    final sortedWorkouts = [...widget.profile.workouts]
      ..sort((a, b) => b.date.compareTo(a.date));

    return Column(
      children: [
        // ── Week navigation ──
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          child: Row(children: [
            IconButton(
              icon: const Icon(Icons.chevron_left),
              onPressed: () => setState(
                  () => _weekStart = _weekStart.subtract(const Duration(days: 7))),
            ),
            Expanded(
              child: Text(_weekRangeLabel(),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
            ),
            IconButton(
              icon: const Icon(Icons.chevron_right),
              onPressed: () => setState(
                  () => _weekStart = _weekStart.add(const Duration(days: 7))),
            ),
          ]),
        ),
        // ── Day cells ──
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: List.generate(7, (i) {
              final day = _weekStart.add(Duration(days: i));
              final isSelected = _sameDay(day, _selectedDay);
              final hasData = _dayData(day) != null &&
                  _dayData(day)!.exercises.isNotEmpty;
              final primary = Theme.of(context).colorScheme.primary;
              return GestureDetector(
                onTap: () => setState(() => _selectedDay = day),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Selected-day dot above
                    Container(
                      width: 5, height: 5,
                      decoration: BoxDecoration(
                        color: isSelected ? primary : Colors.transparent,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(_dayLabels[i],
                        style: TextStyle(
                          fontSize: 11,
                          color: isSelected ? primary : Colors.white54,
                          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                        )),
                    const SizedBox(height: 4),
                    Container(
                      width: 34, height: 34,
                      decoration: BoxDecoration(
                        color: isSelected ? primary : Colors.transparent,
                        shape: BoxShape.circle,
                      ),
                      child: Center(
                        child: Text('${day.day}',
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                              color: isSelected ? Colors.white : Colors.white70,
                            )),
                      ),
                    ),
                    const SizedBox(height: 4),
                    // Dot for days that have exercises
                    Container(
                      width: 4, height: 4,
                      decoration: BoxDecoration(
                        color: hasData && !isSelected ? primary : Colors.transparent,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ],
                ),
              );
            }),
          ),
        ),
        const SizedBox(height: 8),
        const Divider(height: 1),
        // ── Scrollable content: programmed exercises + completed workouts ──
        Expanded(
          child: CustomScrollView(
            slivers: [
              // Day label
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                  child: Text(_selectedDayLabel(),
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                ),
              ),
              // Programmed exercises
              if (exercises.isEmpty)
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Text('No exercises programmed for this day.',
                        style: TextStyle(color: Colors.white54, fontSize: 13)),
                  ),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                  sliver: SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (_, i) {
                        final ex = exercises[i];
                        final done = ex.sets.where((s) => s.status == SetStatus.succeeded).length;
                        final missed = ex.sets.where((s) => s.status == SetStatus.missed).length;
                        return Dismissible(
                          key: Key('prog_${_selectedDay.toIso8601String()}_$i'),
                          direction: DismissDirection.endToStart,
                          background: _dismissBackground(),
                          onDismissed: (_) {
                            setState(() {
                              dayData!.exercises.removeAt(i);
                              if (dayData.exercises.isEmpty) {
                                widget.profile.program.remove(dayData);
                              }
                            });
                            widget.onChanged();
                          },
                          child: Card(
                            margin: const EdgeInsets.only(bottom: 8),
                            child: ListTile(
                              title: Text(ex.name,
                                  style: const TextStyle(fontWeight: FontWeight.w600)),
                              subtitle: Text(
                                '${ex.sets.length} set${ex.sets.length == 1 ? '' : 's'}'
                                '${done > 0 ? '  ✓$done' : ''}${missed > 0 ? '  ✗$missed' : ''}',
                                style: const TextStyle(fontSize: 12, color: Colors.white54),
                              ),
                              trailing: const Icon(Icons.chevron_right, color: Colors.white54),
                              onTap: () async {
                                await Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => ProgramExerciseScreen(
                                      exercise: ex,
                                      onChanged: () {
                                        setState(() {});
                                        widget.onChanged();
                                      },
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        );
                      },
                      childCount: exercises.length,
                    ),
                  ),
                ),
              // Completed Workouts header
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Row(children: [
                    Icon(Icons.fitness_center, size: 15,
                        color: Theme.of(context).colorScheme.primary),
                    const SizedBox(width: 6),
                    const Text('Completed Workouts',
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                  ]),
                ),
              ),
              // Completed workouts list
              if (sortedWorkouts.isEmpty)
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: Text('No workouts logged yet.',
                        style: TextStyle(color: Colors.white54, fontSize: 13)),
                  ),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  sliver: SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (_, i) {
                        final workout = sortedWorkouts[i];
                        final exNames = workout.exercises.map((e) => e.liftName).join(' · ');
                        return Dismissible(
                          key: Key('workout_${workout.date.toIso8601String()}'),
                          direction: DismissDirection.endToStart,
                          background: _dismissBackground(),
                          onDismissed: (_) {
                            setState(() => widget.profile.workouts.remove(workout));
                            widget.onChanged();
                          },
                          child: Card(
                            margin: const EdgeInsets.only(bottom: 8),
                            child: ListTile(
                              contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 6),
                              title: Row(children: [
                                Text(_fmtDate(workout.date),
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w600, fontSize: 15)),
                                const SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: Theme.of(context).colorScheme.primaryContainer,
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(workout.type.label,
                                      style: TextStyle(
                                          fontSize: 10,
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onPrimaryContainer)),
                                ),
                              ]),
                              subtitle: Text(
                                  exNames.isEmpty ? 'No exercises' : exNames,
                                  style: const TextStyle(
                                      fontSize: 12, color: Colors.white60),
                                  overflow: TextOverflow.ellipsis),
                              trailing: const Icon(Icons.chevron_right),
                              onTap: () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => WorkoutDetailScreen(
                                    workout: workout,
                                    profile: widget.profile,
                                    currentUserName: widget.currentUserName,
                                    isOwnProfile: true,
                                    onChanged: () {
                                      setState(() {});
                                      widget.onChanged();
                                    },
                                  ),
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                      childCount: sortedWorkouts.length,
                    ),
                  ),
                ),
            ],
          ),
        ),
        // ── Action buttons ──
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  icon: const Icon(Icons.calendar_today_outlined),
                  label: const Text('Add Program'),
                  onPressed: _addExercises,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  icon: const Icon(Icons.fitness_center),
                  label: const Text('Add Workout'),
                  onPressed: widget.onAddWorkout,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ─── Program Exercise Screen ──────────────────────────────────────────────────

class _ProgSetRow {
  final TextEditingController reps;
  final TextEditingController weight;
  final TextEditingController rpe;
  SetStatus status;

  _ProgSetRow({String reps = '5', String weight = '', String rpe = ''})
      : reps = TextEditingController(text: reps),
        weight = TextEditingController(text: weight),
        rpe = TextEditingController(text: rpe),
        status = SetStatus.none;

  factory _ProgSetRow.fromProgramSet(ProgramSet s) {
    final row = _ProgSetRow(
      reps: s.reps.toString(),
      weight: s.weight != null
          ? (s.weight! % 1 == 0
              ? s.weight!.toInt().toString()
              : s.weight!.toStringAsFixed(1))
          : '',
      rpe: s.rpe != null ? s.rpe!.toStringAsFixed(1) : '',
    );
    row.status = s.status;
    return row;
  }

  void dispose() {
    reps.dispose();
    weight.dispose();
    rpe.dispose();
  }
}

class ProgramExerciseScreen extends StatefulWidget {
  final ProgramExercise exercise;
  final VoidCallback onChanged;

  const ProgramExerciseScreen(
      {super.key, required this.exercise, required this.onChanged});

  @override
  State<ProgramExerciseScreen> createState() => _ProgramExerciseScreenState();
}

class _ProgramExerciseScreenState extends State<ProgramExerciseScreen> {
  late final List<_ProgSetRow> _rows;
  String _unit = 'lbs';

  @override
  void initState() {
    super.initState();
    _unit = widget.exercise.sets.isNotEmpty
        ? widget.exercise.sets.first.unit
        : 'lbs';
    _rows = widget.exercise.sets
        .map((s) => _ProgSetRow.fromProgramSet(s))
        .toList();
    if (_rows.isEmpty) {
      _rows.addAll([_ProgSetRow(), _ProgSetRow(), _ProgSetRow()]);
    }
  }

  @override
  void dispose() {
    for (final r in _rows) { r.dispose(); }
    super.dispose();
  }

  void _save() {
    widget.exercise.sets = _rows.map((r) => ProgramSet(
          reps: int.tryParse(r.reps.text) ?? 5,
          weight: double.tryParse(r.weight.text),
          unit: _unit,
          rpe: double.tryParse(r.rpe.text),
          status: r.status,
        )).toList();
    widget.onChanged();
    Navigator.pop(context);
  }

  Widget _statusBtn(int idx, SetStatus target, IconData icon, Color activeColor) {
    final row = _rows[idx];
    final active = row.status == target;
    return GestureDetector(
      onTap: () => setState(() {
        row.status = active ? SetStatus.none : target;
      }),
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: active ? activeColor : Colors.white10,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Icon(icon,
            size: 18, color: active ? Colors.white : Colors.white38),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.exercise.name,
            style: const TextStyle(fontWeight: FontWeight.bold)),
        centerTitle: true,
        actions: [
          TextButton(
            onPressed: _save,
            child: const Text('Save', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
      body: Column(
        children: [
          // Unit selector
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Row(children: [
              const Text('Unit:', style: TextStyle(color: Colors.white70)),
              const SizedBox(width: 12),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'lbs', label: Text('lbs')),
                  ButtonSegment(value: 'kg', label: Text('kg')),
                ],
                selected: {_unit},
                onSelectionChanged: (s) =>
                    setState(() => _unit = s.first),
                style: const ButtonStyle(
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ]),
          ),
          // Column headers
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(children: [
              SizedBox(width: 28,
                  child: Text('Set', style: TextStyle(fontSize: 11, color: Colors.white38))),
              SizedBox(width: 8),
              SizedBox(width: 60,
                  child: Text('Reps', style: TextStyle(fontSize: 11, color: Colors.white38))),
              SizedBox(width: 8),
              Expanded(
                  child: Text('Weight', style: TextStyle(fontSize: 11, color: Colors.white38))),
              SizedBox(width: 8),
              SizedBox(width: 52,
                  child: Text('RPE', style: TextStyle(fontSize: 11, color: Colors.white38),
                      textAlign: TextAlign.center)),
              SizedBox(width: 84),
            ]),
          ),
          // Set rows
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              itemCount: _rows.length,
              itemBuilder: (_, idx) {
                final row = _rows[idx];
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: 28,
                        child: Text('${idx + 1}',
                            style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                                color: Theme.of(context).colorScheme.primary)),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 60,
                        child: TextField(
                          controller: row.reps,
                          keyboardType: TextInputType.number,
                          textAlign: TextAlign.center,
                          decoration: const InputDecoration(
                            isDense: true,
                            border: OutlineInputBorder(),
                            contentPadding:
                                EdgeInsets.symmetric(vertical: 8, horizontal: 6),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: row.weight,
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          textAlign: TextAlign.center,
                          decoration: const InputDecoration(
                            isDense: true,
                            border: OutlineInputBorder(),
                            contentPadding:
                                EdgeInsets.symmetric(vertical: 8, horizontal: 6),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 52,
                        child: TextField(
                          controller: row.rpe,
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          textAlign: TextAlign.center,
                          decoration: const InputDecoration(
                            isDense: true,
                            border: OutlineInputBorder(),
                            contentPadding:
                                EdgeInsets.symmetric(vertical: 8, horizontal: 6),
                            hintText: '–',
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      _statusBtn(idx, SetStatus.missed, Icons.close, Colors.red),
                      const SizedBox(width: 6),
                      _statusBtn(idx, SetStatus.succeeded, Icons.check, Colors.green),
                    ],
                  ),
                );
              },
            ),
          ),
          // Add / remove set
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  icon: const Icon(Icons.add_circle_outline, size: 22),
                  tooltip: 'Add set',
                  onPressed: () => setState(() {
                    final prev = _rows.isNotEmpty ? _rows.last : null;
                    _rows.add(_ProgSetRow(
                      reps: prev?.reps.text ?? '5',
                      weight: prev?.weight.text ?? '',
                      rpe: prev?.rpe.text ?? '',
                    ));
                  }),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  visualDensity: VisualDensity.compact,
                ),
                const SizedBox(width: 16),
                IconButton(
                  icon: const Icon(Icons.remove_circle_outline, size: 22),
                  tooltip: 'Remove last set',
                  onPressed: _rows.isEmpty
                      ? null
                      : () => setState(() => _rows.removeLast()..dispose()),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Settings Screen ──────────────────────────────────────────────────────────

class SettingsScreen extends StatefulWidget {
  final Profile profile;
  const SettingsScreen({super.key, required this.profile});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _usernameCtrl;
  late final TextEditingController _emailCtrl;
  bool _saving = false;
  String? _error;
  String? _success;

  @override
  void initState() {
    super.initState();
    _usernameCtrl = TextEditingController(text: widget.profile.username);
    _emailCtrl = TextEditingController(text: widget.profile.email ?? '');
  }

  @override
  void dispose() {
    _usernameCtrl.dispose();
    _emailCtrl.dispose();
    super.dispose();
  }

  Future<void> _saveDetails() async {
    final newUsername = _usernameCtrl.text.trim();
    final newEmail = _emailCtrl.text.trim();
    if (newUsername.isEmpty) {
      setState(() => _error = 'Username cannot be empty.');
      return;
    }
    // Check uniqueness if username changed
    if (newUsername != widget.profile.username) {
      final snap = await FirebaseFirestore.instance
          .collection('profiles')
          .where('username', isEqualTo: newUsername)
          .limit(1)
          .get();
      if (snap.docs.isNotEmpty && snap.docs.first.id != widget.profile.id) {
        setState(() => _error = 'That username is already taken.');
        return;
      }
    }
    setState(() { _saving = true; _error = null; _success = null; });
    widget.profile.username = newUsername;
    if (newEmail.isNotEmpty) widget.profile.email = newEmail;
    await LiftStore.saveProfile(widget.profile);
    setState(() { _saving = false; _success = 'Details saved.'; });
  }

  Future<void> _changePassword() async {
    final currentCtrl = TextEditingController();
    final newCtrl = TextEditingController();
    final confirmCtrl = TextEditingController();
    bool step2 = false; // false = enter current pw, true = enter new pw
    String? dialogError;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: const Text('Change Password'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!step2) ...[
                const Text('Enter your current password to continue.',
                    style: TextStyle(fontSize: 13, color: Colors.white70)),
                const SizedBox(height: 16),
                TextField(
                  controller: currentCtrl,
                  obscureText: true,
                  autofocus: true,
                  decoration: const InputDecoration(
                      labelText: 'Current password',
                      border: OutlineInputBorder()),
                ),
              ] else ...[
                TextField(
                  controller: newCtrl,
                  obscureText: true,
                  autofocus: true,
                  decoration: const InputDecoration(
                      labelText: 'New password',
                      border: OutlineInputBorder()),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: confirmCtrl,
                  obscureText: true,
                  decoration: const InputDecoration(
                      labelText: 'Confirm new password',
                      border: OutlineInputBorder()),
                ),
              ],
              if (dialogError != null) ...[
                const SizedBox(height: 10),
                Text(dialogError!,
                    style: const TextStyle(color: Colors.redAccent, fontSize: 13)),
              ],
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel')),
            FilledButton(
              onPressed: () async {
                if (!step2) {
                  // Verify current password
                  final hash = _hashPassword(currentCtrl.text);
                  if (hash != widget.profile.passwordHash) {
                    setDlg(() => dialogError = 'Incorrect password.');
                    return;
                  }
                  setDlg(() { step2 = true; dialogError = null; });
                } else {
                  // Save new password
                  final pw = newCtrl.text;
                  final confirm = confirmCtrl.text;
                  if (pw.length < 6) {
                    setDlg(() => dialogError = 'Password must be at least 6 characters.');
                    return;
                  }
                  if (pw != confirm) {
                    setDlg(() => dialogError = 'Passwords do not match.');
                    return;
                  }
                  widget.profile.passwordHash = _hashPassword(pw);
                  await LiftStore.saveProfile(widget.profile);
                  if (ctx.mounted) Navigator.pop(ctx);
                  setState(() => _success = 'Password updated.');
                }
              },
              child: Text(step2 ? 'Save' : 'Continue'),
            ),
          ],
        ),
      ),
    );
    currentCtrl.dispose();
    newCtrl.dispose();
    confirmCtrl.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings', style: TextStyle(fontWeight: FontWeight.bold)),
        centerTitle: true,
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const Text('Account Details',
              style: TextStyle(fontSize: 13, color: Colors.white54, fontWeight: FontWeight.w600)),
          const SizedBox(height: 16),
          TextField(
            controller: _usernameCtrl,
            decoration: const InputDecoration(
              labelText: 'Username',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.person_outline),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _emailCtrl,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(
              labelText: 'Email',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.email_outlined),
            ),
          ),
          const SizedBox(height: 20),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(_error!, style: const TextStyle(color: Colors.redAccent)),
            ),
          if (_success != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(_success!, style: const TextStyle(color: Colors.greenAccent)),
            ),
          FilledButton(
            onPressed: _saving ? null : _saveDetails,
            child: _saving
                ? const SizedBox(
                    width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Save Changes'),
          ),
          const SizedBox(height: 32),
          const Divider(),
          const SizedBox(height: 24),
          const Text('Security',
              style: TextStyle(fontSize: 13, color: Colors.white54, fontWeight: FontWeight.w600)),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            icon: const Icon(Icons.lock_outline),
            label: const Text('Change Password'),
            onPressed: _changePassword,
          ),
        ],
      ),
    );
  }
}

// ─── Admin Screen ─────────────────────────────────────────────────────────────

class AdminScreen extends StatefulWidget {
  final Profile currentUser;
  const AdminScreen({super.key, required this.currentUser});

  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> {
  String _initials(String name) {
    final parts = name.trim().split(' ');
    if (parts.length >= 2) return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    return name.substring(0, name.length >= 2 ? 2 : 1).toUpperCase();
  }

  void _editProfile(Profile profile) {
    final usernameCtrl = TextEditingController(text: profile.username);
    final emailCtrl = TextEditingController(text: profile.email ?? '');
    final passwordCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Edit — ${profile.name}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: usernameCtrl,
              decoration: const InputDecoration(
                  labelText: 'Username', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: emailCtrl,
              decoration: const InputDecoration(
                  labelText: 'Email', border: OutlineInputBorder()),
              keyboardType: TextInputType.emailAddress,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: passwordCtrl,
              obscureText: true,
              decoration: const InputDecoration(
                  labelText: 'New password (leave blank to keep)',
                  border: OutlineInputBorder()),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              final newUsername = usernameCtrl.text.trim();
              final newEmail = emailCtrl.text.trim();
              final newPassword = passwordCtrl.text;
              Navigator.pop(ctx);
              if (newUsername.isNotEmpty) profile.username = newUsername;
              if (newEmail.isNotEmpty) profile.email = newEmail;
              if (newPassword.isNotEmpty) {
                profile.passwordHash = _hashPassword(newPassword);
              }
              await LiftStore.saveProfile(profile);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _confirmDelete(Profile profile) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete profile?'),
        content: Text('Permanently remove "${profile.name}" and all their data?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () {
              Navigator.pop(context);
              LiftStore.deleteProfile(profile.id!);
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Admin Panel',
            style: TextStyle(fontWeight: FontWeight.bold)),
        centerTitle: true,
      ),
      body: StreamBuilder<List<Profile>>(
        stream: LiftStore.stream(),
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final profiles = snap.data!;
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: profiles.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, i) {
              final p = profiles[i];
              return Card(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 12),
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 22,
                        backgroundImage: p.photoData != null
                            ? NetworkImage(p.photoData!)
                            : null,
                        child: p.photoData == null
                            ? Text(_initials(p.name),
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold))
                            : null,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(children: [
                              Text(p.name,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 15)),
                              if (p.isAdmin) ...[
                                const SizedBox(width: 6),
                                const Icon(Icons.admin_panel_settings,
                                    size: 14, color: Colors.amber),
                              ],
                            ]),
                            const SizedBox(height: 2),
                            _adminRow(Icons.person_outline, 'Username',
                                p.username),
                            _adminRow(Icons.email_outlined, 'Email',
                                p.email ?? '—'),
                            _adminRow(Icons.lock_outline, 'Password hash',
                                p.passwordHash != null
                                    ? '${p.passwordHash!.substring(0, 16)}…'
                                    : '—'),
                          ],
                        ),
                      ),
                      // Toggle admin — Muppy's admin is permanent
                      if (p.id != widget.currentUser.id)
                        IconButton(
                          icon: Icon(
                            p.isAdmin
                                ? Icons.admin_panel_settings
                                : Icons.person_outline,
                            color: p.isAdmin ? Colors.amber : null,
                          ),
                          tooltip: p.isAdmin ? 'Revoke admin' : 'Grant admin',
                          onPressed: p.username.toLowerCase() == 'muppy'
                              ? null // Muppy's admin can never be revoked
                              : () async {
                                  p.isAdmin = !p.isAdmin;
                                  await LiftStore.saveProfile(p);
                                },
                        ),
                      IconButton(
                        icon: const Icon(Icons.edit_outlined),
                        tooltip: 'Edit profile',
                        onPressed: () => _editProfile(p),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline,
                            color: Colors.red),
                        tooltip: 'Delete profile',
                        // Cannot delete Muppy
                        onPressed: (p.id == null ||
                                p.username.toLowerCase() == 'muppy')
                            ? null
                            : () => _confirmDelete(p),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  Widget _adminRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Row(
        children: [
          Icon(icon, size: 12, color: Colors.white38),
          const SizedBox(width: 4),
          Text('$label: ',
              style: const TextStyle(fontSize: 11, color: Colors.white38)),
          Expanded(
            child: Text(value,
                style: const TextStyle(fontSize: 11, color: Colors.white70),
                overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }
}

// ─── Exercise Picker Dialog ───────────────────────────────────────────────────

class _ExercisePickerDialog extends StatefulWidget {
  final List<Lift> existingLifts;
  final Set<String> alreadyAdded;
  final void Function(List<String> names, List<String> newNames) onConfirm;

  const _ExercisePickerDialog({
    required this.existingLifts,
    required this.alreadyAdded,
    required this.onConfirm,
  });

  @override
  State<_ExercisePickerDialog> createState() => _ExercisePickerDialogState();
}

class _ExercisePickerDialogState extends State<_ExercisePickerDialog> {
  final _searchCtrl = TextEditingController();
  String _query = '';
  final Set<String> _selected = {};

  List<Lift> get _filtered => widget.existingLifts
      .where((l) =>
          !widget.alreadyAdded.contains(l.name) &&
          l.name.toLowerCase().contains(_query.toLowerCase()))
      .toList();

  bool get _isNew =>
      _query.isNotEmpty &&
      !widget.existingLifts
          .any((l) => l.name.toLowerCase() == _query.toLowerCase()) &&
      !widget.alreadyAdded.contains(_query);

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add Exercise'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _searchCtrl,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                hintText: 'Search or type new exercise...',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
              ),
              onChanged: (v) => setState(() => _query = v.trim()),
            ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 280),
              child: ListView(
                shrinkWrap: true,
                children: [
                  ..._filtered.map((l) => CheckboxListTile(
                        title: Text(l.name),
                        value: _selected.contains(l.name),
                        onChanged: (v) => setState(() => v == true
                            ? _selected.add(l.name)
                            : _selected.remove(l.name)),
                      )),
                  if (_isNew)
                    CheckboxListTile(
                      secondary: const Icon(Icons.add_circle_outline),
                      title: Text('Create "$_query"'),
                      value: _selected.contains(_query),
                      onChanged: (v) => setState(() => v == true
                          ? _selected.add(_query)
                          : _selected.remove(_query)),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton(
          onPressed: _selected.isEmpty
              ? null
              : () {
                  Navigator.pop(context);
                  final existingNames =
                      widget.existingLifts.map((l) => l.name).toSet();
                  final newNames = _selected
                      .where((n) => !existingNames.contains(n))
                      .toList();
                  widget.onConfirm(_selected.toList(), newNames);
                },
          child: const Text('Add'),
        ),
      ],
    );
  }
}

// ─── Workout Detail Screen ────────────────────────────────────────────────────

class WorkoutDetailScreen extends StatefulWidget {
  final Workout workout;
  final Profile profile;
  final String currentUserName;
  final bool isOwnProfile;
  final VoidCallback onChanged;

  const WorkoutDetailScreen({
    super.key,
    required this.workout,
    required this.profile,
    required this.currentUserName,
    required this.isOwnProfile,
    required this.onChanged,
  });

  @override
  State<WorkoutDetailScreen> createState() => _WorkoutDetailScreenState();
}

class _WorkoutDetailScreenState extends State<WorkoutDetailScreen> {
  final _commentCtrl = TextEditingController();

  @override
  void dispose() {
    _commentCtrl.dispose();
    super.dispose();
  }

  String _fmt(DateTime d) {
    const m = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${m[d.month - 1]} ${d.day}, ${d.year}';
  }

  void _addComment() {
    final text = _commentCtrl.text.trim();
    if (text.isEmpty) return;
    setState(() {
      widget.workout.comments.add(Comment(
        author: widget.currentUserName,
        text: text,
        date: DateTime.now(),
      ));
      _commentCtrl.clear();
    });
    widget.onChanged();
  }

  void _deleteComment(int index) {
    setState(() => widget.workout.comments.removeAt(index));
    widget.onChanged();
  }

  void _deleteWorkout() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete workout?'),
        content: Text('Remove this ${widget.workout.type.label} workout from ${_fmt(widget.workout.date)}?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () {
              Navigator.pop(context);
              widget.profile.workouts.remove(widget.workout);
              widget.onChanged();
              Navigator.pop(context);
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  void _deleteExercise(WorkoutExercise ex) {
    setState(() => widget.workout.exercises.remove(ex));
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_fmt(widget.workout.date),
            style: const TextStyle(fontWeight: FontWeight.bold)),
        centerTitle: true,
        actions: [
          if (widget.isOwnProfile)
            IconButton(
              icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
              onPressed: _deleteWorkout,
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              children: [
                Wrap(
                  spacing: 8,
                  children: [
                    Chip(label: Text(widget.workout.type.label)),
                    if (widget.workout.timeCap != null)
                      Chip(label: Text('${widget.workout.timeCap} min')),
                  ],
                ),
                if (widget.workout.result != null && widget.workout.result!.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.emoji_events_outlined, color: Colors.amber),
                      title: Text(widget.workout.result!,
                          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                      subtitle: Text(switch (widget.workout.type) {
                        WorkoutType.amrap => 'Rounds Completed',
                        WorkoutType.emom => 'Completed',
                        WorkoutType.forTime => 'Completion Time',
                        _ => 'Result',
                      }),
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                ...widget.workout.exercises.map((ex) => _buildExerciseCard(ex)),
                _SocialSection(
                  currentUserName: widget.profile.name,
                  reactions: widget.workout.reactions,
                  comments: widget.workout.comments,
                  onChanged: widget.onChanged,
                  onDeleteComment: _deleteComment,
                  isOwnProfile: widget.isOwnProfile,
                ),
              ],
            ),
          ),
          if (!widget.isOwnProfile)
            _CommentInputBar(
              controller: _commentCtrl,
              onSubmit: _addComment,
            ),
        ],
      ),
    );
  }

  Widget _buildExerciseCard(WorkoutExercise ex) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(
                child: Text(ex.liftName,
                    style: const TextStyle(
                        fontSize: 17, fontWeight: FontWeight.bold)),
              ),
              if (widget.isOwnProfile)
                IconButton(
                  icon: const Icon(Icons.delete_outline,
                      color: Colors.redAccent, size: 20),
                  onPressed: () => _deleteExercise(ex),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
            ]),
            const SizedBox(height: 8),
            if (widget.workout.type == WorkoutType.strength) ...[
              if (ex.sets.isEmpty)
                const Text('No sets logged', style: TextStyle(color: Colors.white54))
              else ...[
                const Row(children: [
                  SizedBox(width: 36, child: Text('Set', style: TextStyle(fontSize: 12, color: Colors.white54))),
                  SizedBox(width: 8),
                  SizedBox(width: 52, child: Text('Reps', style: TextStyle(fontSize: 12, color: Colors.white54))),
                  SizedBox(width: 8),
                  Text('Weight', style: TextStyle(fontSize: 12, color: Colors.white54)),
                ]),
                const SizedBox(height: 4),
                ...ex.sets.asMap().entries.map((e) {
                  final s = e.value;
                  final w = s.weight % 1 == 0
                      ? s.weight.toInt().toString()
                      : s.weight.toStringAsFixed(1);
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(children: [
                      SizedBox(
                        width: 36,
                        child: Text('${e.key + 1}',
                            style: TextStyle(
                                fontSize: 14,
                                color: Theme.of(context).colorScheme.primary,
                                fontWeight: FontWeight.bold)),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(width: 52, child: Text('${s.reps}', style: const TextStyle(fontSize: 14))),
                      const SizedBox(width: 8),
                      Text('$w ${s.unit}', style: const TextStyle(fontSize: 14)),
                    ]),
                  );
                }),
              ],
            ] else ...[
              Row(children: [
                Text('${ex.reps} reps', style: const TextStyle(fontSize: 15)),
                if (ex.weight != null) ...[
                  const SizedBox(width: 16),
                  Text(
                    '${ex.weight!.toStringAsFixed(ex.weight! % 1 == 0 ? 0 : 1)} ${ex.unit}',
                    style: const TextStyle(fontSize: 15),
                  ),
                ],
              ]),
              if (ex.otherType != null && ex.otherValue != null) ...[
                const SizedBox(height: 4),
                Text('${ex.otherType}: ${ex.otherValue}',
                    style: const TextStyle(
                        fontSize: 13, color: Colors.white60)),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

// ─── Social Section ───────────────────────────────────────────────────────────

class _SocialSection extends StatefulWidget {
  final String currentUserName;
  final Map<String, List<String>> reactions;
  final List<Comment> comments;
  final VoidCallback onChanged;
  final void Function(int) onDeleteComment;
  final bool isOwnProfile;

  const _SocialSection({
    required this.currentUserName,
    required this.reactions,
    required this.comments,
    required this.onChanged,
    required this.onDeleteComment,
    this.isOwnProfile = false,
  });

  @override
  State<_SocialSection> createState() => _SocialSectionState();
}

class _SocialSectionState extends State<_SocialSection> {
  static const _emojis = ['💪', '🔥', '👏', '🏆', '😤'];

  void _toggle(String emoji) {
    setState(() {
      final list = widget.reactions.putIfAbsent(emoji, () => []);
      if (list.contains(widget.currentUserName)) {
        list.remove(widget.currentUserName);
        if (list.isEmpty) widget.reactions.remove(emoji);
      } else {
        list.add(widget.currentUserName);
      }
    });
    widget.onChanged();
  }

  String _timeAgo(DateTime d) {
    final diff = DateTime.now().difference(d);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    const m = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${m[d.month - 1]} ${d.day}';
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Divider(height: 32),
          // Reactions
          Builder(builder: (context) {
            final activeReactions = _emojis
                .where((e) => (widget.reactions[e] ?? []).isNotEmpty)
                .toList();
            if (widget.isOwnProfile) {
              // Read-only: show counts of reactions others left
              if (activeReactions.isEmpty) return const SizedBox.shrink();
              return Wrap(
                spacing: 8,
                runSpacing: 8,
                children: activeReactions.map((emoji) {
                  final list = widget.reactions[emoji]!;
                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.white10,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(emoji, style: const TextStyle(fontSize: 20)),
                        const SizedBox(width: 4),
                        Text('${list.length}',
                            style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: Colors.white60)),
                      ],
                    ),
                  );
                }).toList(),
              );
            }
            // Interactive reaction buttons for other profiles
            return Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _emojis.map((emoji) {
                final list = widget.reactions[emoji] ?? [];
                final reacted = list.contains(widget.currentUserName);
                return GestureDetector(
                  onTap: () => _toggle(emoji),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: reacted
                          ? Theme.of(context).colorScheme.primaryContainer
                          : Colors.white10,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: reacted
                            ? Theme.of(context).colorScheme.primary
                            : Colors.transparent,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(emoji, style: const TextStyle(fontSize: 20)),
                        if (list.isNotEmpty) ...[
                          const SizedBox(width: 4),
                          Text(
                            '${list.length}',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: reacted
                                  ? Theme.of(context).colorScheme.onPrimaryContainer
                                  : Colors.white60,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                );
              }).toList(),
            );
          }),
          const SizedBox(height: 20),
          // Comments header
          Text(
            'Comments (${widget.comments.length})',
            style: const TextStyle(
                fontSize: 13, color: Colors.white54, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          if (widget.comments.isEmpty)
            const Text('No comments yet.',
                style: TextStyle(fontSize: 13, color: Colors.white38))
          else
            ...widget.comments.asMap().entries.map((e) {
              final comment = e.value;
              final isOwn = comment.author == widget.currentUserName;
              return Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    CircleAvatar(
                      radius: 14,
                      backgroundColor:
                          Theme.of(context).colorScheme.primaryContainer,
                      child: Text(
                        comment.author[0].toUpperCase(),
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: Theme.of(context).colorScheme.onPrimaryContainer,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            Text(comment.author,
                                style: const TextStyle(
                                    fontSize: 13, fontWeight: FontWeight.w600)),
                            const SizedBox(width: 8),
                            Text(_timeAgo(comment.date),
                                style: const TextStyle(
                                    fontSize: 11, color: Colors.white38)),
                          ]),
                          const SizedBox(height: 3),
                          Text(comment.text,
                              style: const TextStyle(
                                  fontSize: 14, color: Colors.white)),
                        ],
                      ),
                    ),
                    if (isOwn)
                      GestureDetector(
                        onTap: () => widget.onDeleteComment(e.key),
                        child: const Icon(Icons.close,
                            size: 14, color: Colors.white38),
                      ),
                  ],
                ),
              );
            }),
          const SizedBox(height: 72), // breathing room above input bar
        ],
      ),
    );
  }
}

class _CommentInputBar extends StatelessWidget {
  final TextEditingController controller;
  final VoidCallback onSubmit;

  const _CommentInputBar({required this.controller, required this.onSubmit});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          border: Border(
              top: BorderSide(color: Colors.white12)),
        ),
        padding: EdgeInsets.fromLTRB(
            12, 8, 12, MediaQuery.of(context).viewInsets.bottom + 8),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => onSubmit(),
                decoration: const InputDecoration(
                  hintText: 'Add a comment…',
                  border: OutlineInputBorder(),
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              icon: Icon(Icons.send_rounded,
                  color: Theme.of(context).colorScheme.primary),
              onPressed: onSubmit,
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Weight Calculator Card ───────────────────────────────────────────────────

class _WeightCalculatorCard extends StatefulWidget {
  const _WeightCalculatorCard();

  @override
  State<_WeightCalculatorCard> createState() => _WeightCalculatorCardState();
}

class _WeightCalculatorCardState extends State<_WeightCalculatorCard> {
  final _baseCtrl = TextEditingController();
  final _customCtrl = TextEditingController();
  bool _expanded = false;

  // Descending: 110 → 40, 3 rows × 5 cols
  static const _pcts = [
    110, 105, 100, 95, 90,
    85,  80,  75,  70, 65,
    60,  55,  50,  45, 40,
  ];

  @override
  void dispose() {
    _baseCtrl.dispose();
    _customCtrl.dispose();
    super.dispose();
  }

  String _calc(double? base, int pct) {
    if (base == null) return '—';
    final v = base * pct / 100;
    return v % 1 == 0 ? v.toInt().toString() : v.toStringAsFixed(1);
  }

  @override
  Widget build(BuildContext context) {
    final base = double.tryParse(_baseCtrl.text.trim());
    final customPct = double.tryParse(_customCtrl.text.trim());

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GestureDetector(
              onTap: () => setState(() => _expanded = !_expanded),
              behavior: HitTestBehavior.opaque,
              child: Row(children: [
                Icon(Icons.calculate_outlined,
                    size: 16, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 6),
                const Expanded(
                  child: Text('Weight Calculator',
                      style: TextStyle(fontSize: 12, color: Colors.white54)),
                ),
                Icon(
                  _expanded ? Icons.expand_less : Icons.expand_more,
                  size: 18,
                  color: Colors.white38,
                ),
              ]),
            ),
            if (_expanded) ...[
            const SizedBox(height: 12),
            // Base weight input
            TextField(
              controller: _baseCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Base weight',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 10),
            // Custom % row
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _customCtrl,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Custom %',
                    suffixText: '%',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color:
                        Theme.of(context).colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    (base != null && customPct != null)
                        ? (base * customPct / 100).toStringAsFixed(1)
                        : '—',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context)
                          .colorScheme
                          .onPrimaryContainer,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ]),
            const SizedBox(height: 14),
            const Divider(height: 1),
            const SizedBox(height: 10),
            // 3 × 5 grid
            ...List.generate(3, (row) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: List.generate(5, (col) {
                    final pct = _pcts[row * 5 + col];
                    final active = pct == 100;
                    return Expanded(
                      child: Container(
                        margin: const EdgeInsets.symmetric(horizontal: 2),
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        decoration: BoxDecoration(
                          color: active
                              ? Theme.of(context)
                                  .colorScheme
                                  .primaryContainer
                              : Colors.white10,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text('$pct%',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: active
                                      ? Theme.of(context)
                                          .colorScheme
                                          .onPrimaryContainer
                                      : Colors.white54,
                                  fontWeight: FontWeight.w600,
                                )),
                            const SizedBox(height: 2),
                            Text(
                              _calc(base, pct),
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: active
                                    ? Theme.of(context)
                                        .colorScheme
                                        .primary
                                    : Colors.white,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }),
                ),
              );
            }),
            ], // end if (_expanded)
          ],
        ),
      ),
    );
  }
}
