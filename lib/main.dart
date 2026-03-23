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

final themeNotifier = ValueNotifier<ThemeMode>(ThemeMode.dark);

// Adaptive text colors — automatically returns dark-mode or light-mode variant
// depending on the current themeNotifier value. Rebuilds correctly because the
// entire widget tree is under a ValueListenableBuilder on themeNotifier.
bool get _isLight => themeNotifier.value == ThemeMode.light;
Color get _w38 => _isLight ? Colors.black38  : const Color(0x61FFFFFF);
Color get _w54 => _isLight ? Colors.black54  : const Color(0x8AFFFFFF);
Color get _w60 => _isLight ? Colors.black54  : const Color(0x99FFFFFF);
Color get _w70 => _isLight ? Colors.black87  : const Color(0xB3FFFFFF);
Color get _wt  => _isLight ? Colors.black    : Colors.white;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  final prefs = await SharedPreferences.getInstance();
  final savedId = prefs.getString('currentUserId');
  final savedUsername = prefs.getString('currentUserName');
  final savedTheme = prefs.getString('themeMode');
  themeNotifier.value = savedTheme == 'light' ? ThemeMode.light : ThemeMode.dark;
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
  String category; // 'barbell', 'bodyweight', 'gymnastics', 'cardio'
  List<RepRecord> history; // every logged record
  Map<int, RepRecord> bests; // best weight per rep count (computed)
  List<Comment> comments;
  Map<String, List<String>> reactions;

  Lift({
    required this.name,
    this.category = 'barbell',
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
    if (category == 'bodyweight' || category == 'gymnastics') {
      // Track record with highest rep count
      RepRecord? best;
      for (final r in history) {
        if (best == null || r.reps > best.reps) best = r;
      }
      if (best != null) bests[best.reps] = best;
    } else if (category == 'cardio') {
      // Track record with highest value (stored in weight field)
      RepRecord? best;
      for (final r in history) {
        if (best == null || r.weight > best.weight) best = r;
      }
      if (best != null) bests[0] = best;
    } else {
      // Barbell: best weight per rep count
      for (final r in history) {
        final cur = bests[r.reps];
        if (cur == null || r.weight > cur.weight) bests[r.reps] = r;
      }
    }
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'category': category,
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
      category: j['category'] as String? ?? 'barbell',
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
  int weeklyWorkoutGoal;
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
    this.weeklyWorkoutGoal = 3,
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
        'weeklyWorkoutGoal': weeklyWorkoutGoal,
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
      weeklyWorkoutGoal: j['weeklyWorkoutGoal'] as int? ?? 3,
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
  // Preserves what was entered during config (for planned display)
  String? plannedUnit;   // 'lbs', 'kg', or '%'
  double? plannedWeight; // raw entered value (may be a % like 80)

  WorkoutExercise({
    required this.liftName,
    List<WorkoutSet>? sets,
    this.reps = 10,
    this.weight,
    this.unit = 'lbs',
    this.otherType,
    this.otherValue,
    this.plannedUnit,
    this.plannedWeight,
  }) : sets = sets ?? [];

  Map<String, dynamic> toJson() => {
        'liftName': liftName,
        'sets': sets.map((s) => s.toJson()).toList(),
        'reps': reps,
        if (weight != null) 'weight': weight,
        'unit': unit,
        if (otherType != null) 'otherType': otherType,
        if (otherValue != null && otherValue!.isNotEmpty) 'otherValue': otherValue,
        if (plannedUnit != null) 'plannedUnit': plannedUnit,
        if (plannedWeight != null) 'plannedWeight': plannedWeight,
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
        plannedUnit: j['plannedUnit'] as String?,
        plannedWeight: (j['plannedWeight'] as num?)?.toDouble(),
      );
}

class Workout {
  DateTime date;
  WorkoutType type;
  int? timeCap; // minutes
  String? result;
  String? notes;
  bool completed; // false = planned template, true = logged/done
  List<WorkoutExercise> exercises;
  List<Comment> comments;
  Map<String, List<String>> reactions;

  Workout({
    required this.date,
    this.type = WorkoutType.strength,
    this.timeCap,
    this.result,
    this.notes,
    this.completed = true,
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
        if (notes != null && notes!.isNotEmpty) 'notes': notes,
        if (!completed) 'completed': false,
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
        notes: j['notes'] as String?,
        completed: j['completed'] as bool? ?? true,
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
  double? pct; // percent of working max (emomStrength)
  SetStatus status;

  ProgramSet({
    this.reps = 5,
    this.weight,
    this.unit = 'lbs',
    this.rpe,
    this.pct,
    this.status = SetStatus.none,
  });

  Map<String, dynamic> toJson() => {
        'reps': reps,
        if (weight != null) 'weight': weight,
        'unit': unit,
        if (rpe != null) 'rpe': rpe,
        if (pct != null) 'pct': pct,
        'status': status.name,
      };

  factory ProgramSet.fromJson(Map<String, dynamic> j) => ProgramSet(
        reps: j['reps'] as int? ?? 5,
        weight: (j['weight'] as num?)?.toDouble(),
        unit: j['unit'] as String? ?? 'lbs',
        rpe: (j['rpe'] as num?)?.toDouble(),
        pct: (j['pct'] as num?)?.toDouble(),
        status: SetStatus.values.firstWhere(
          (s) => s.name == (j['status'] as String? ?? 'none'),
          orElse: () => SetStatus.none,
        ),
      );
}

class ProgramExercise {
  String name;
  List<ProgramSet> sets;
  String block; // 'warmUp', 'main', or 'coolDown'
  String? groupId;         // exercises sharing a groupId form an EMOM/AMRAP group
  String? groupType;       // 'emom', 'emomStrength', or 'amrap'
  int? groupIntervalMin;   // EMOM: minutes per interval
  int? groupIntervalSec;   // EMOM: additional seconds per interval
  int? groupTotalSets;     // EMOM: total sets; AMRAP: time cap in minutes
  double? groupWorkingMax; // emomStrength: working max in lbs
  bool completed;          // true when user marks this exercise/group as done

  ProgramExercise({
    required this.name,
    List<ProgramSet>? sets,
    this.block = 'main',
    this.groupId,
    this.groupType,
    this.groupIntervalMin,
    this.groupIntervalSec,
    this.groupTotalSets,
    this.groupWorkingMax,
    this.completed = false,
  }) : sets = sets ?? [];

  Map<String, dynamic> toJson() => {
        'name': name,
        'sets': sets.map((s) => s.toJson()).toList(),
        'block': block,
        if (groupId != null) 'groupId': groupId,
        if (groupType != null) 'groupType': groupType,
        if (groupIntervalMin != null) 'groupIntervalMin': groupIntervalMin,
        if (groupIntervalSec != null && groupIntervalSec != 0) 'groupIntervalSec': groupIntervalSec,
        if (groupTotalSets != null) 'groupTotalSets': groupTotalSets,
        if (groupWorkingMax != null) 'groupWorkingMax': groupWorkingMax,
        if (completed) 'completed': completed,
      };

  factory ProgramExercise.fromJson(Map<String, dynamic> j) => ProgramExercise(
        name: j['name'] as String,
        sets: (j['sets'] as List<dynamic>? ?? [])
            .map((e) => ProgramSet.fromJson(e as Map<String, dynamic>))
            .toList(),
        block: j['block'] as String? ?? 'main',
        groupId: j['groupId'] as String?,
        groupType: j['groupType'] as String?,
        groupIntervalMin: j['groupIntervalMin'] as int?,
        groupIntervalSec: j['groupIntervalSec'] as int? ?? 0,
        groupTotalSets: j['groupTotalSets'] as int?,
        groupWorkingMax: (j['groupWorkingMax'] as num?)?.toDouble(),
        completed: j['completed'] as bool? ?? false,
      );
}

class ProgramDay {
  DateTime date;
  List<ProgramExercise> exercises;
  bool completed;
  String? notes;

  ProgramDay({
    required this.date,
    List<ProgramExercise>? exercises,
    this.completed = false,
    this.notes,
  }) : exercises = exercises ?? [];

  Map<String, dynamic> toJson() => {
        'date': date.toIso8601String(),
        'exercises': exercises.map((e) => e.toJson()).toList(),
        if (completed) 'completed': completed,
        if (notes != null && notes!.isNotEmpty) 'notes': notes,
      };

  factory ProgramDay.fromJson(Map<String, dynamic> j) => ProgramDay(
        date: DateTime.parse(j['date'] as String),
        exercises: (j['exercises'] as List<dynamic>? ?? [])
            .map((e) => ProgramExercise.fromJson(e as Map<String, dynamic>))
            .toList(),
        completed: j['completed'] as bool? ?? false,
        notes: j['notes'] as String?,
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
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeNotifier,
      builder: (context2, mode, child) => MaterialApp(
        title: 'Lift Tracker',
        debugShowCheckedModeBanner: false,
        themeMode: mode,
        theme: ThemeData(
          colorScheme: const ColorScheme(
            brightness: Brightness.light,
            // Primary: deep forest green #295A39
            primary: Color(0xFF295A39),
            onPrimary: Colors.white,
            primaryContainer: Color(0xFFB7DFC4),
            onPrimaryContainer: Color(0xFF00210C),
            // Secondary: warm sage green
            secondary: Color(0xFF4E7A5C),
            onSecondary: Colors.white,
            secondaryContainer: Color(0xFFCFEDD9),
            onSecondaryContainer: Color(0xFF0B2118),
            // Tertiary: muted olive/gold complement
            tertiary: Color(0xFF7A6E40),
            onTertiary: Colors.white,
            tertiaryContainer: Color(0xFFEFE2B0),
            onTertiaryContainer: Color(0xFF261E00),
            // Error
            error: Color(0xFFBA1A1A),
            onError: Colors.white,
            errorContainer: Color(0xFFFFDAD6),
            onErrorContainer: Color(0xFF410002),
            // Surfaces: white background, black text
            surface: Colors.white,
            onSurface: Colors.black,
            surfaceContainerHighest: Color(0xFFE8F5EC),
            onSurfaceVariant: Color(0xFF1A1A1A),
            outline: Color(0xFF295A39),
            outlineVariant: Color(0xFFB7DFC4),
            shadow: Colors.black,
            scrim: Colors.black,
            inverseSurface: Color(0xFF2D3B31),
            onInverseSurface: Color(0xFFEDF4EE),
            inversePrimary: Color(0xFF9CCFAA),
          ),
          scaffoldBackgroundColor: Colors.white,
          useMaterial3: true,
        ),
        darkTheme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF1565C0),
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
        ),
        home: _AuthGate(savedId: savedId, savedUsername: savedUsername),
      ),
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
              Text(
                'This account has no password yet. Create one to continue.',
                style: TextStyle(fontSize: 13, color: _w60),
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
                Text('Sign in to continue',
                    style: TextStyle(fontSize: 14, color: _w54)),
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
                    Padding(
                      padding: EdgeInsets.symmetric(horizontal: 12),
                      child: Text('or',
                          style: TextStyle(color: _w38)),
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
                Text('Set up your account',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 16, color: _w54)),
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
            return Center(
              child: Text(
                'No profiles yet.\nTap + to create one.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16, color: _w54),
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
                        style: TextStyle(
                            fontSize: 13, color: _w54),
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
    String category = 'barbell';
    final categories = ['barbell', 'bodyweight', 'gymnastics', 'cardio'];
    final categoryLabels = {
      'barbell': 'Barbell',
      'bodyweight': 'Bodyweight',
      'gymnastics': 'Gymnastics',
      'cardio': 'Cardio',
    };
    showDialog(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: const Text('New Lift'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                initialValue: category,
                decoration: const InputDecoration(
                  labelText: 'Category',
                  border: OutlineInputBorder(),
                ),
                items: categories.map((c) => DropdownMenuItem(
                  value: c,
                  child: Text(categoryLabels[c]!),
                )).toList(),
                onChanged: (v) { if (v != null) setDlg(() => category = v); },
              ),
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                autofocus: true,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(
                  labelText: 'Name',
                  hintText: switch (category) {
                    'barbell' => 'e.g. Back Squat',
                    'bodyweight' => 'e.g. Pull Up',
                    'gymnastics' => 'e.g. Muscle Up',
                    'cardio' => 'e.g. Row 1000m',
                    _ => 'Exercise name',
                  },
                  border: const OutlineInputBorder(),
                ),
                onSubmitted: (_) => _confirmAdd(controller.text, category),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel')),
            FilledButton(
              onPressed: () => _confirmAdd(controller.text, category),
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
  }

  void _confirmAdd(String name, [String category = 'barbell']) {
    name = name.trim();
    if (name.isEmpty) return;
    Navigator.pop(context);
    setState(() => lifts.add(Lift(name: name, category: category)));
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
    if (lift.history.isEmpty) return 'No records yet';
    final cat = lift.category;
    if (cat == 'bodyweight' || cat == 'gymnastics') {
      final maxReps = lift.history.map((r) => r.reps).reduce(max);
      return 'Best: $maxReps reps';
    }
    if (cat == 'cardio') {
      final best = lift.bests[0];
      if (best == null) return 'No records yet';
      final v = best.weight % 1 == 0 ? best.weight.toInt().toString() : best.weight.toStringAsFixed(1);
      return 'Best: $v ${best.unit}';
    }
    // Barbell
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
          if (isOwn)
            IconButton(
              icon: const Icon(Icons.logout),
              tooltip: 'Log Out',
              onPressed: () async {
                final prefs = await SharedPreferences.getInstance();
                await prefs.remove('currentUserId');
                await prefs.remove('currentUserName');
                if (!context.mounted) return;
                Navigator.of(context).pushReplacement(
                  MaterialPageRoute(builder: (_) => const SignInScreen()),
                );
              },
            ),
        ],
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'Dashboard'),
            Tab(text: 'Lifts'),
            Tab(text: 'Training'),
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

  int _workoutsThisWeek() {
    final now = DateTime.now();
    // Week starts on Sunday
    final startOfWeek = DateTime(now.year, now.month, now.day)
        .subtract(Duration(days: now.weekday % 7));
    return widget.profile.workouts
        .where((w) => !w.date.isBefore(startOfWeek))
        .length;
  }

  void _editWeeklyGoal() {
    final ctrl = TextEditingController(
        text: widget.profile.weeklyWorkoutGoal.toString());
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Weekly Workout Goal'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(hintText: 'Workouts per week'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              final val = int.tryParse(ctrl.text.trim());
              if (val != null && val > 0) {
                Navigator.pop(context);
                setState(() => widget.profile.weeklyWorkoutGoal = val);
                widget.onChanged();
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
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
            Padding(
              padding: EdgeInsets.only(bottom: 16),
              child: Text('No lifts logged yet.',
                  style: TextStyle(color: _w54)),
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
                      style: TextStyle(
                          fontSize: 12, color: _w60)),
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
            Padding(
              padding: EdgeInsets.only(bottom: 16),
              child: Text('No workouts logged yet.',
                  style: TextStyle(color: _w54)),
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
                      style: TextStyle(
                          fontSize: 12, color: _w60),
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
            Text('No goals set.',
                style: TextStyle(color: _w54))
          else
            ...widget.profile.goals.map((goal) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(children: [
                    Text('• ', style: TextStyle(color: _w70)),
                    Expanded(
                        child: Text(goal,
                            style: TextStyle(
                                fontSize: 14, color: _w70))),
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
            style: TextStyle(fontSize: 16, color: _w60),
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
            style: TextStyle(
                fontSize: 14,
                color: _w54,
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
                            Text('Recent Lift',
                                style: TextStyle(
                                    fontSize: 12, color: _w54)),
                          ]),
                          const SizedBox(height: 12),
                          if (mostRecent == null)
                            Text('No lifts logged yet.',
                                style: TextStyle(
                                    fontSize: 13, color: _w54))
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
                              style: TextStyle(
                                  fontSize: 12, color: _w38),
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
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.flag_outlined,
                                  size: 13,
                                  color: Theme.of(context).colorScheme.primary),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text('Goals',
                                    style: TextStyle(
                                        fontSize: 11, color: _w54)),
                              ),
                              GestureDetector(
                                onTap: _addGoal,
                                child: Icon(Icons.add_circle_outline,
                                    size: 16,
                                    color: Theme.of(context).colorScheme.primary),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          if (widget.profile.goals.isEmpty)
                            Text('Tap + to add',
                                style: TextStyle(
                                    fontSize: 11, color: _w38))
                          else
                            ...widget.profile.goals.asMap().entries.map(
                                  (e) => Padding(
                                    padding: const EdgeInsets.only(bottom: 5),
                                    child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text('• ',
                                            style: TextStyle(
                                                fontSize: 12,
                                                color: _w60)),
                                        Expanded(
                                          child: Text(e.value,
                                              style: TextStyle(
                                                  fontSize: 12,
                                                  color: _w70)),
                                        ),
                                        GestureDetector(
                                          onTap: () => _removeGoal(e.key),
                                          child: const Icon(Icons.close,
                                              size: 12, color: Colors.white30),
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
          const SizedBox(height: 16),
          // Weekly workout goal card
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              child: Row(
                children: [
                  Icon(Icons.calendar_today_outlined,
                      size: 16,
                      color: Theme.of(context).colorScheme.primary),
                  const SizedBox(width: 8),
                  Text('Weekly Workouts',
                      style: TextStyle(fontSize: 13, color: _w54)),
                  const Spacer(),
                  GestureDetector(
                    onTap: _editWeeklyGoal,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        RichText(
                          text: TextSpan(
                            children: [
                              TextSpan(
                                text: '${_workoutsThisWeek()}',
                                style: TextStyle(
                                  fontSize: 42,
                                  fontWeight: FontWeight.bold,
                                  color: _workoutsThisWeek() >=
                                          widget.profile.weeklyWorkoutGoal
                                      ? Colors.greenAccent
                                      : Theme.of(context).colorScheme.primary,
                                  height: 1,
                                ),
                              ),
                              TextSpan(
                                text: '/${widget.profile.weeklyWorkoutGoal}',
                                style: TextStyle(
                                  fontSize: 22,
                                  fontWeight: FontWeight.w500,
                                  color: _w38,
                                  height: 1,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 6),
                        const Icon(Icons.edit, size: 12, color: Colors.white24),
                      ],
                    ),
                  ),
                ],
              ),
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
      return Center(
        child: Text(
          'No lifts yet.\nTap + to add your first lift.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 16, color: _w54),
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
                    TextStyle(fontSize: 13, color: _w60)),
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
    final recent = items.take(4).toList();

    if (recent.isEmpty) {
      return Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text('No recent activity from others yet.',
              style: TextStyle(color: _w54, fontSize: 13)),
        ),
      );
    }

    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.hardEdge,
      child: SizedBox(
        height: 260,
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
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
                              style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: _wt,
                                  fontSize: 13)),
                          TextSpan(
                              text: ' $description',
                              style: TextStyle(
                                  color: _w70, fontSize: 13)),
                        ]),
                      ),
                      const SizedBox(height: 2),
                      Text(_timeAgo(item.date),
                          style: TextStyle(
                              fontSize: 11, color: _w38)),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right,
                    size: 16, color: _w38),
              ],
            ),
          ),
        );
      }).toList(),
        ),
      ),
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
          return Center(
            child: Text('No other profiles yet.',
                style: TextStyle(color: _w54)),
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
                      TextStyle(fontSize: 12, color: _w54),
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
    final cat = widget.lift.category;
    final isBodyweight = cat == 'bodyweight' || cat == 'gymnastics';
    final isCardio = cat == 'cardio';

    int selectedReps = existing?.reps ?? 1;
    final valueController = TextEditingController(
      text: existing != null && existing.weight > 0
          ? (existing.weight % 1 == 0
              ? existing.weight.toInt().toString()
              : existing.weight.toStringAsFixed(1))
          : '',
    );
    String unit = existing?.unit ?? (isCardio ? 'sec' : isBodyweight ? 'bw' : 'lbs');
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
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
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

              if (isCardio) ...[
                // Cardio: value + sec/cal toggle
                Text('Metric', style: TextStyle(color: _w60, fontSize: 13)),
                const SizedBox(height: 8),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'sec', label: Text('Time (sec)')),
                    ButtonSegment(value: 'cal', label: Text('Calories')),
                  ],
                  selected: {unit},
                  onSelectionChanged: (s) => setModalState(() => unit = s.first),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: valueController,
                  autofocus: true,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                    labelText: unit == 'sec' ? 'Time (seconds)' : 'Calories',
                    border: const OutlineInputBorder(),
                    suffixText: unit,
                  ),
                ),
              ] else ...[
                // Reps picker (barbell + bodyweight/gymnastics)
                Text('Reps', style: TextStyle(color: _w60, fontSize: 13)),
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
                            color: selected ? Colors.white : _w70,
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
                if (!isBodyweight) ...[
                  // Barbell: weight field
                  const SizedBox(height: 20),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: TextField(
                          controller: valueController,
                          autofocus: existing == null,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
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
                        onSelectionChanged: (s) => setModalState(() => unit = s.first),
                      ),
                    ],
                  ),
                ],
              ],

              const SizedBox(height: 24),
              FilledButton(
                onPressed: () {
                  RepRecord record;
                  if (isCardio) {
                    final v = double.tryParse(valueController.text.trim());
                    if (v == null || v <= 0) return;
                    record = RepRecord(reps: 0, weight: v, unit: unit, date: selectedDate);
                  } else if (isBodyweight) {
                    record = RepRecord(reps: selectedReps, weight: 0, unit: 'bw', date: selectedDate);
                  } else {
                    final w = double.tryParse(valueController.text.trim());
                    if (w == null || w <= 0) return;
                    record = RepRecord(reps: selectedReps, weight: w, unit: unit, date: selectedDate);
                  }
                  Navigator.pop(ctx);
                  setState(() {
                    _selectedDate = selectedDate;
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

  Widget _buildBestCard() {
    final cat = widget.lift.category;
    final isBodyweight = cat == 'bodyweight' || cat == 'gymnastics';
    final isCardio = cat == 'cardio';

    if (isBodyweight) {
      if (widget.lift.history.isEmpty) return const SizedBox.shrink();
      final maxReps = widget.lift.history.map((r) => r.reps).reduce(max);
      final best = widget.lift.history.firstWhere((r) => r.reps == maxReps);
      return Card(
        margin: const EdgeInsets.only(bottom: 12),
        color: Theme.of(context).colorScheme.primaryContainer,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          child: Row(children: [
            const Icon(Icons.emoji_events, size: 32, color: Colors.amber),
            const SizedBox(width: 12),
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Best', style: TextStyle(fontSize: 13, color: _w70)),
              Text('$maxReps reps',
                  style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
            ]),
            const Spacer(),
            Text(_formatDate(best.date), style: TextStyle(fontSize: 12, color: _w60)),
          ]),
        ),
      );
    }

    if (isCardio) {
      final best = widget.lift.bests[0];
      if (best == null) return const SizedBox.shrink();
      final v = best.weight % 1 == 0 ? best.weight.toInt().toString() : best.weight.toStringAsFixed(1);
      return Card(
        margin: const EdgeInsets.only(bottom: 12),
        color: Theme.of(context).colorScheme.primaryContainer,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          child: Row(children: [
            const Icon(Icons.emoji_events, size: 32, color: Colors.amber),
            const SizedBox(width: 12),
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Best', style: TextStyle(fontSize: 13, color: _w70)),
              Text('$v ${best.unit}',
                  style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
            ]),
            const Spacer(),
            Text(_formatDate(best.date), style: TextStyle(fontSize: 12, color: _w60)),
          ]),
        ),
      );
    }

    // Barbell: show 1RM
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
                Text('Most Recent 1RM',
                    style: TextStyle(fontSize: 13, color: _w70)),
                Text('$w ${oneRM.unit}',
                    style: const TextStyle(
                        fontSize: 28, fontWeight: FontWeight.bold)),
              ],
            ),
            const Spacer(),
            Text(_formatDate(oneRM.date),
                style: TextStyle(fontSize: 12, color: _w60)),
          ],
        ),
      ),
    );
  }

  Widget _buildChart() {
    if (widget.lift.history.isEmpty) return const SizedBox.shrink();
    final cat = widget.lift.category;
    final isBodyweight = cat == 'bodyweight' || cat == 'gymnastics';
    final isCardio = cat == 'cardio';

    final records = [...widget.lift.history]
      ..sort((a, b) => a.date.compareTo(b.date));

    // ── Barbell: one line per rep count ──────────────────────────────────────
    if (!isBodyweight && !isCardio) {
      // Palette for up to 8 distinct RM lines
      const lineColors = [
        Color(0xFF4FC3F7), // 1RM – light blue
        Color(0xFF81C784), // 2RM – green
        Color(0xFFFFB74D), // 3RM – orange
        Color(0xFFE57373), // 4RM – red
        Color(0xFFBA68C8), // 5RM – purple
        Color(0xFF4DB6AC), // 6RM – teal
        Color(0xFFF06292), // 8RM – pink
        Color(0xFFFFD54F), // 10RM+ – amber
      ];

      // Group records by reps, sorted ascending
      final repGroups = <int, List<RepRecord>>{};
      for (final r in records) {
        repGroups.putIfAbsent(r.reps, () => []).add(r);
      }
      final sortedReps = repGroups.keys.toList()..sort();

      // Build spots per group
      final seriesList = <({int reps, List<FlSpot> spots, List<RepRecord> recs})>[];
      for (final reps in sortedReps) {
        final recs = repGroups[reps]!;
        final spots = recs.map((r) =>
            FlSpot(r.date.millisecondsSinceEpoch / 86400000.0, r.weight)).toList();
        if (spots.isNotEmpty) seriesList.add((reps: reps, spots: spots, recs: recs));
      }
      if (seriesList.isEmpty) return const SizedBox.shrink();

      final allWeights = seriesList.expand((s) => s.recs.map((r) => r.weight)).toList();
      final minY = allWeights.reduce(min);
      final maxY = allWeights.reduce(max);
      final yPadding = max((maxY - minY) * 0.15, 10.0);

      final allSpots = seriesList.expand((s) => s.spots).toList();
      final xInterval = allSpots.length > 1
          ? (allSpots.map((s) => s.x).reduce(max) - allSpots.map((s) => s.x).reduce(min)) /
              (allSpots.length > 4 ? 3 : allSpots.length - 1)
          : 1.0;

      final bars = seriesList.asMap().entries.map((e) {
        final color = lineColors[e.key % lineColors.length];
        final s = e.value;
        return LineChartBarData(
          spots: s.spots,
          isCurved: true,
          curveSmoothness: 0.3,
          color: color,
          barWidth: 2.5,
          dotData: FlDotData(
            show: true,
            getDotPainter: (spot, pct, bar, idx) => FlDotCirclePainter(
              radius: 4,
              color: color,
              strokeWidth: 2,
              strokeColor: Colors.white,
            ),
          ),
          belowBarData: BarAreaData(show: false),
        );
      }).toList();

      return Card(
        margin: const EdgeInsets.only(bottom: 12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 16, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 12, bottom: 8),
                child: Text('Weight Progress by RM',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: _w70)),
              ),
              // Legend
              Padding(
                padding: const EdgeInsets.only(left: 12, bottom: 12),
                child: Wrap(
                  spacing: 12,
                  runSpacing: 6,
                  children: seriesList.asMap().entries.map((e) {
                    final color = lineColors[e.key % lineColors.length];
                    final label = e.value.reps == 1 ? '1RM' : '${e.value.reps}RM';
                    return Row(mainAxisSize: MainAxisSize.min, children: [
                      Container(width: 14, height: 3, color: color),
                      const SizedBox(width: 5),
                      Text(label, style: TextStyle(fontSize: 11, color: _w54)),
                    ]);
                  }).toList(),
                ),
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
                      getDrawingHorizontalLine: (_) =>
                          const FlLine(color: Colors.white12, strokeWidth: 1),
                    ),
                    borderData: FlBorderData(show: false),
                    titlesData: FlTitlesData(
                      leftTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          reservedSize: 44,
                          getTitlesWidget: (v, _) => Text(v.toInt().toString(),
                              style: TextStyle(fontSize: 11, color: _w54)),
                        ),
                      ),
                      bottomTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          reservedSize: 28,
                          interval: xInterval,
                          getTitlesWidget: (value, _) {
                            final date = DateTime.fromMillisecondsSinceEpoch(
                                (value * 86400000).toInt());
                            const months = ['Jan','Feb','Mar','Apr','May','Jun',
                                            'Jul','Aug','Sep','Oct','Nov','Dec'];
                            return Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text('${months[date.month - 1]} ${date.day}',
                                  style: TextStyle(fontSize: 10, color: _w54)),
                            );
                          },
                        ),
                      ),
                      rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                      topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    ),
                    lineBarsData: bars,
                    lineTouchData: LineTouchData(
                      touchTooltipData: LineTouchTooltipData(
                        getTooltipItems: (touchedSpots) => touchedSpots.map((s) {
                          final series = seriesList[s.barIndex];
                          final rec = series.recs[s.spotIndex];
                          final w = rec.weight % 1 == 0
                              ? rec.weight.toInt().toString()
                              : rec.weight.toStringAsFixed(1);
                          return LineTooltipItem(
                            '${series.reps}RM  ·  $w ${rec.unit}\n${_formatDate(rec.date)}',
                            TextStyle(
                                fontSize: 12,
                                color: lineColors[s.barIndex % lineColors.length],
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

    // ── Bodyweight / Cardio: single line (unchanged) ──────────────────────────
    final spots = records.map((r) {
      final daysSinceEpoch = r.date.millisecondsSinceEpoch / 86400000.0;
      return FlSpot(daysSinceEpoch, isBodyweight ? r.reps.toDouble() : r.weight);
    }).toList();

    final yVals = isBodyweight
        ? records.map((r) => r.reps.toDouble()).toList()
        : records.map((r) => r.weight).toList();
    if (yVals.every((v) => v == 0)) return const SizedBox.shrink();
    final minY = yVals.reduce(min);
    final maxY = yVals.reduce(max);
    final yPadding = max((maxY - minY) * 0.15, 10.0);
    final chartLabel = isBodyweight ? 'Reps Progress' : 'Performance Progress';

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 16, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 12, bottom: 12),
              child: Text(chartLabel,
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: _w70)),
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
                    getDrawingHorizontalLine: (_) =>
                        const FlLine(color: Colors.white12, strokeWidth: 1),
                  ),
                  borderData: FlBorderData(show: false),
                  titlesData: FlTitlesData(
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 44,
                        getTitlesWidget: (value, _) => Text(value.toInt().toString(),
                            style: TextStyle(fontSize: 11, color: _w54)),
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
                        getTitlesWidget: (value, _) {
                          final date = DateTime.fromMillisecondsSinceEpoch(
                              (value * 86400000).toInt());
                          const months = ['Jan','Feb','Mar','Apr','May','Jun',
                                          'Jul','Aug','Sep','Oct','Nov','Dec'];
                          return Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text('${months[date.month - 1]} ${date.day}',
                                style: TextStyle(fontSize: 10, color: _w54)),
                          );
                        },
                      ),
                    ),
                    rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
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
                        getDotPainter: (spot, pct, bar, idx) => FlDotCirclePainter(
                          radius: 4,
                          color: Theme.of(context).colorScheme.primary,
                          strokeWidth: 2,
                          strokeColor: Colors.white,
                        ),
                      ),
                      belowBarData: BarAreaData(
                        show: true,
                        color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.15),
                      ),
                    ),
                  ],
                  lineTouchData: LineTouchData(
                    touchTooltipData: LineTouchTooltipData(
                      getTooltipItems: (touchedSpots) => touchedSpots.map((s) {
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
                        final valStr = isBodyweight ? '${rec.reps} reps' : '$w ${rec.unit}';
                        return LineTooltipItem(
                          '$valStr\n${_formatDate(date)}',
                          TextStyle(fontSize: 12, color: _wt, fontWeight: FontWeight.w500),
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
                _buildBestCard(),
                _buildChart(),
                if (sorted.isEmpty)
                  Padding(
                    padding: EdgeInsets.symmetric(vertical: 32),
                    child: Text(
                      'No records yet.\nTap + to log a lift.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 16, color: _w54),
                    ),
                  )
                else
                  ...sorted.map((entry) {
                    final historyIndex = entry.key;
                    final rec = entry.value;
                    final cat = widget.lift.category;
                    final isBodyweight = cat == 'bodyweight' || cat == 'gymnastics';
                    final isCardio = cat == 'cardio';
                    final isBest = widget.lift.bests[isCardio ? 0 : rec.reps] == rec;

                    // Leading badge text
                    final String badgeText;
                    if (isBodyweight) {
                      badgeText = '${rec.reps}\nreps';
                    } else if (isCardio) {
                      badgeText = rec.unit;
                    } else {
                      badgeText = '${rec.reps}RM';
                    }

                    // Main value text
                    final String valueText;
                    if (isBodyweight) {
                      valueText = '${rec.reps} reps';
                    } else {
                      final w = rec.weight % 1 == 0
                          ? rec.weight.toInt().toString()
                          : rec.weight.toStringAsFixed(1);
                      valueText = '$w ${rec.unit}';
                    }

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
                              badgeText,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onPrimaryContainer,
                              ),
                            ),
                          ),
                          title: Row(children: [
                            Text(valueText,
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
                              style: TextStyle(
                                  fontSize: 12, color: _w54)),
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
  final TextEditingController otherValue;
  SetStatus status = SetStatus.none;
  _SetRow({String reps = '5', String weight = '', String otherValue = ''})
      : reps = TextEditingController(text: reps),
        weight = TextEditingController(text: weight),
        otherValue = TextEditingController(text: otherValue);
  void dispose() {
    reps.dispose();
    weight.dispose();
    otherValue.dispose();
  }
}

class WorkoutScreen extends StatefulWidget {
  final Profile profile;
  final VoidCallback onSaved;
  final Workout? editingWorkout; // if set, editing existing workout

  const WorkoutScreen(
      {super.key, required this.profile, required this.onSaved, this.editingWorkout});

  @override
  State<WorkoutScreen> createState() => _WorkoutScreenState();
}

class _WorkoutScreenState extends State<WorkoutScreen> {
  late DateTime _date;
  late WorkoutType _type;
  late final _timeCtrl = TextEditingController(
      text: widget.editingWorkout?.timeCap?.toString() ?? '');
  late final _resultCtrl = TextEditingController(
      text: widget.editingWorkout?.result ?? '');
  // AMRAP split result: "X rounds + Y reps"
  late final _amrapRoundsCtrl = TextEditingController(
      text: _parseAmrapRounds(widget.editingWorkout?.result));
  late final _amrapRepsCtrl = TextEditingController(
      text: _parseAmrapReps(widget.editingWorkout?.result));
  late final _completionNotesCtrl = TextEditingController(
      text: widget.editingWorkout?.notes ?? '');

  static String _parseAmrapRounds(String? result) {
    if (result == null) return '';
    final m = RegExp(r'^(\d+)').firstMatch(result);
    return m?.group(1) ?? '';
  }

  static String _parseAmrapReps(String? result) {
    if (result == null) return '';
    final m = RegExp(r'\+\s*(\d+)').firstMatch(result);
    return m?.group(1) ?? '';
  }
  final List<WorkoutExercise> _exercises = [];
  final Map<String, TextEditingController> _repsCtrl = {};
  final Map<String, TextEditingController> _weightCtrl = {};
  final Map<String, List<_SetRow>> _setCtrl = {};
  final Map<String, String> _unitSel = {};
  final Map<String, FixedExtentScrollController> _otherScrollCtrl = {};
  final Map<String, TextEditingController> _otherValueCtrl = {};
  final Map<String, int> _otherSelIdx = {};
  // Strength config phase
  final Set<String> _confirmed = {};
  final Map<String, TextEditingController> _setsCountCtrl = {};
  static const _otherOptions = ['RPE', 'Height'];

  @override
  void initState() {
    super.initState();
    final ew = widget.editingWorkout;
    _date = ew?.date ?? DateTime.now();
    _type = ew?.type ?? WorkoutType.strength;
    if (ew != null) {
      for (final ex in ew.exercises) {
        _exercises.add(WorkoutExercise(
          liftName: ex.liftName,
          reps: ex.reps,
          weight: ex.weight,
          unit: ex.unit,
          sets: List.from(ex.sets),
          otherType: ex.otherType,
          otherValue: ex.otherValue,
          plannedUnit: ex.plannedUnit,
          plannedWeight: ex.plannedWeight,
        ));
        final name = ex.liftName;
        _repsCtrl[name] = TextEditingController(text: ex.reps.toString());
        _weightCtrl[name] =
            TextEditingController(text: ex.weight?.toString() ?? '');
        _unitSel[name] = ex.unit;
        _otherScrollCtrl[name] = FixedExtentScrollController();
        _otherValueCtrl[name] =
            TextEditingController(text: ex.otherValue ?? '');
        _otherSelIdx[name] =
            _otherOptions.indexOf(ex.otherType ?? 'RPE').clamp(0, _otherOptions.length - 1);
        _setsCountCtrl[name] = TextEditingController(
            text: ex.sets.isNotEmpty ? ex.sets.length.toString() : '3');
        if (_type == WorkoutType.strength) {
          _setCtrl[name] = ex.sets.isEmpty
              ? [_SetRow(), _SetRow(), _SetRow()]
              : ex.sets
                  .map((s) => _SetRow(
                      reps: s.reps.toString(),
                      weight: s.weight == 0
                          ? ''
                          : s.weight % 1 == 0
                              ? s.weight.toInt().toString()
                              : s.weight.toStringAsFixed(1)))
                  .toList();
          // Always enter execution phase when editing any existing workout
          _confirmed.add(name);
        } else {
          _setCtrl[name] = [];
        }
      }
    }
  }

  @override
  void dispose() {
    _timeCtrl.dispose();
    _resultCtrl.dispose();
    _amrapRoundsCtrl.dispose();
    _amrapRepsCtrl.dispose();
    _completionNotesCtrl.dispose();
    for (final c in _repsCtrl.values) { c.dispose(); }
    for (final c in _weightCtrl.values) { c.dispose(); }
    for (final rows in _setCtrl.values) {
      for (final r in rows) { r.dispose(); }
    }
    for (final c in _otherScrollCtrl.values) { c.dispose(); }
    for (final c in _otherValueCtrl.values) { c.dispose(); }
    for (final c in _setsCountCtrl.values) { c.dispose(); }
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
      _repsCtrl[name] = TextEditingController(text: '5');
      _weightCtrl[name] = TextEditingController();
      _unitSel[name] = 'lbs';
      _otherScrollCtrl[name] = FixedExtentScrollController();
      _otherValueCtrl[name] = TextEditingController();
      _otherSelIdx[name] = 0;
      _setsCountCtrl[name] = TextEditingController(text: '3');
      _setCtrl[name] = []; // empty until confirmed
    });
  }

  void _removeExercise(int i) {
    final name = _exercises[i].liftName;
    setState(() {
      _exercises.removeAt(i);
      _confirmed.remove(name);
      _repsCtrl.remove(name)?.dispose();
      _weightCtrl.remove(name)?.dispose();
      _unitSel.remove(name);
      _otherScrollCtrl.remove(name)?.dispose();
      _otherValueCtrl.remove(name)?.dispose();
      _otherSelIdx.remove(name);
      _setsCountCtrl.remove(name)?.dispose();
      for (final r in _setCtrl.remove(name) ?? []) { r.dispose(); }
    });
  }

  void _confirmSets(String name) {
    final count = int.tryParse(_setsCountCtrl[name]?.text.trim() ?? '') ?? 3;
    final defaultReps = _repsCtrl[name]?.text.trim() ?? '5';
    final defaultWeight = _weightCtrl[name]?.text.trim() ?? '';
    final defaultOther = _otherValueCtrl[name]?.text.trim() ?? '';
    setState(() {
      for (final r in _setCtrl[name] ?? []) { r.dispose(); }
      _setCtrl[name] = List.generate(
        count.clamp(1, 20),
        (_) => _SetRow(reps: defaultReps, weight: defaultWeight, otherValue: defaultOther),
      );
      _confirmed.add(name);
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
    // Determine if any exercise is in execution (confirmed) phase
    final anyConfirmed = _exercises.any((ex) => _confirmed.contains(ex.liftName));
    final isCompleted = _type != WorkoutType.strength || anyConfirmed;

    for (final ex in _exercises) {
      if (_type == WorkoutType.strength) {
        final name = ex.liftName;
        final unit = _unitSel[name] ?? 'lbs';
        final isPercent = unit == '%';
        final oneRM = isPercent ? _oneRM(name) : null;

        if (_confirmed.contains(name)) {
          // Execution phase — use per-set rows
          ex.sets = (_setCtrl[name] ?? [])
              .map((r) {
                final raw = double.tryParse(r.weight.text.trim()) ?? 0;
                final actualWeight = isPercent && oneRM != null ? raw / 100 * oneRM : raw;
                return WorkoutSet(
                  reps: int.tryParse(r.reps.text.trim()) ?? 5,
                  weight: actualWeight,
                  unit: isPercent ? 'lbs' : unit,
                );
              })
              .toList();
        } else {
          // Config phase — generate planned sets from config inputs
          final count = int.tryParse(_setsCountCtrl[name]?.text.trim() ?? '') ?? 3;
          final reps = int.tryParse(_repsCtrl[name]?.text.trim() ?? '') ?? 5;
          final raw = double.tryParse(_weightCtrl[name]?.text.trim() ?? '') ?? 0;
          final actualWeight = isPercent && oneRM != null ? raw / 100 * oneRM : raw;
          ex.plannedUnit = unit;   // preserve original unit ('%', 'lbs', 'kg')
          ex.plannedWeight = raw;  // preserve raw entered value (e.g. 80 for 80%)
          ex.sets = List.generate(
            count.clamp(1, 20),
            (_) => WorkoutSet(reps: reps, weight: actualWeight, unit: isPercent ? 'lbs' : unit),
          );
        }
      } else {
        ex.reps = int.tryParse(_repsCtrl[ex.liftName]?.text ?? '') ?? ex.reps;
        ex.weight = double.tryParse(_weightCtrl[ex.liftName]?.text.trim() ?? '');
        ex.unit = _unitSel[ex.liftName] ?? 'lbs';
        final otherIdx = _otherSelIdx[ex.liftName] ?? 0;
        final otherVal = _otherValueCtrl[ex.liftName]?.text.trim() ?? '';
        ex.otherType = _otherOptions[otherIdx];
        ex.otherValue = otherVal.isEmpty ? null : otherVal;
      }
    }

    final timeCap = int.tryParse(_timeCtrl.text.trim());
    String? result;
    if (_type == WorkoutType.amrap) {
      final rounds = _amrapRoundsCtrl.text.trim();
      final reps = _amrapRepsCtrl.text.trim();
      if (rounds.isNotEmpty || reps.isNotEmpty) {
        result = reps.isNotEmpty ? '$rounds rounds + $reps reps' : '$rounds rounds';
      }
    } else {
      result = _resultCtrl.text.trim().isEmpty ? null : _resultCtrl.text.trim();
    }

    final notesText = _completionNotesCtrl.text.trim().isEmpty
        ? null
        : _completionNotesCtrl.text.trim();
    final ew = widget.editingWorkout;
    if (ew != null) {
      ew.date = _date;
      ew.type = _type;
      ew.timeCap = timeCap;
      ew.result = result;
      ew.notes = notesText;
      ew.exercises = _exercises;
      ew.completed = isCompleted;
    } else {
      widget.profile.workouts.add(Workout(
        date: _date,
        type: _type,
        timeCap: timeCap,
        result: result,
        notes: notesText,
        completed: isCompleted,
        exercises: _exercises,
      ));
    }
    widget.onSaved();
    Navigator.pop(context);
  }

  double? _oneRM(String liftName) {
    try {
      final lift =
          widget.profile.lifts.firstWhere((l) => l.name == liftName);
      return lift.bests[1]?.weight;
    } catch (_) {
      return null;
    }
  }

  Widget _buildAppBarTitle() {
    final isPlannedStrength = widget.editingWorkout != null &&
        !widget.editingWorkout!.completed &&
        _type == WorkoutType.strength;
    if (!isPlannedStrength || _exercises.isEmpty) {
      return Text(
        widget.editingWorkout != null ? 'Edit Workout' : 'New Workout',
        style: const TextStyle(fontWeight: FontWeight.bold),
      );
    }
    // Build summary lines per exercise
    final lines = _exercises.map((ex) {
      final rows = _setCtrl[ex.liftName] ?? [];
      final sets = rows.length;
      final reps = rows.isNotEmpty ? rows.first.reps.text.trim() : '—';
      final pu = ex.plannedUnit ?? _unitSel[ex.liftName] ?? 'lbs';
      final pw = ex.plannedWeight;
      String weightStr;
      if (pw != null && pw != 0) {
        weightStr = pu == '%'
            ? '${pw % 1 == 0 ? pw.toInt() : pw}%'
            : '${pw % 1 == 0 ? pw.toInt() : pw} $pu';
      } else {
        final w = rows.isNotEmpty ? rows.first.weight.text.trim() : '';
        weightStr = w.isEmpty ? 'BW' : '$w ${_unitSel[ex.liftName] ?? 'lbs'}';
      }
      return '$sets sets × $reps reps @ $weightStr';
    }).join('\n');
    return Text(lines,
        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 20),
        textAlign: TextAlign.center);
  }

  String get _timeLabel => switch (_type) {
        WorkoutType.amrap => 'Time Cap (min)',
        WorkoutType.emom => 'Duration (min)',
        WorkoutType.forTime => 'Time to Complete (min)',
        _ => '',
      };

  @override
  Widget build(BuildContext context) {
    final isPlannedStrength = widget.editingWorkout != null &&
        !widget.editingWorkout!.completed &&
        _type == WorkoutType.strength;
    return Scaffold(
      appBar: AppBar(
        title: _buildAppBarTitle(),
        centerTitle: true,
        actions: isPlannedStrength
            ? []
            : [
                TextButton(
                  onPressed: _exercises.isNotEmpty ? _save : null,
                  child: const Text('Save', style: TextStyle(fontSize: 16)),
                ),
                const SizedBox(width: 8),
              ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 100),
        child: Column(
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
            // Workout type dropdown (hidden for planned strength — shown in AppBar)
            if (!(widget.editingWorkout != null &&
                !widget.editingWorkout!.completed &&
                _type == WorkoutType.strength))
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                child: DropdownButtonFormField<WorkoutType>(
                  initialValue: _type,
                  decoration: const InputDecoration(
                    labelText: 'Type',
                    border: OutlineInputBorder(),
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  ),
                  items: WorkoutType.values
                      .map((t) => DropdownMenuItem(
                            value: t,
                            child: Text(t.label),
                          ))
                      .toList(),
                  onChanged: (t) {
                    if (t != null) setState(() => _type = t);
                  },
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
            // Exercise list
            if (_exercises.isEmpty)
              Padding(
                padding: EdgeInsets.symmetric(vertical: 48),
                child: Center(
                  child: Text(
                    'No exercises yet.\nTap + to add exercises.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 16, color: _w54),
                  ),
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    for (int i = 0; i < _exercises.length; i++) ...[
                      if (i > 0) const SizedBox(height: 12),
                      _type == WorkoutType.strength
                          ? _buildStrengthCard(_exercises[i], i)
                          : _buildFunctionalCard(_exercises[i], i),
                    ],
                  ],
                ),
              ),
            // Result field (functional workouts) — below exercises
            if (_type == WorkoutType.amrap)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _amrapRoundsCtrl,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Rounds',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _amrapRepsCtrl,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Reps',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                  ],
                ),
              )
            else if (_type != WorkoutType.strength)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: TextField(
                  controller: _resultCtrl,
                  decoration: InputDecoration(
                    labelText: switch (_type) {
                      WorkoutType.emom => 'Completed?',
                      WorkoutType.forTime => 'Completion Time',
                      _ => 'Result',
                    },
                    hintText: switch (_type) {
                      WorkoutType.emom => 'e.g. Yes / 8 of 10 rounds',
                      WorkoutType.forTime => 'e.g. 12:34',
                      _ => '',
                    },
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
            // Comments box — always shown
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: TextField(
                controller: _completionNotesCtrl,
                minLines: 2,
                maxLines: 5,
                decoration: const InputDecoration(
                  labelText: 'Comments',
                  hintText: 'Notes about this session...',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            // Complete button — only for planned strength execution
            if (isPlannedStrength)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: Center(
                  child: FilledButton(
                    onPressed: _exercises.isNotEmpty ? _save : null,
                    child: const Text('Complete', style: TextStyle(fontSize: 16)),
                  ),
                ),
              ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openExercisePicker,
        icon: const Icon(Icons.add),
        label: const Text('Add Exercise'),
      ),
    );
  }

  Widget _buildFunctionalCard(WorkoutExercise ex, int i) {
    final name = ex.liftName;
    final selIdx = (_otherSelIdx[name] ?? 0).clamp(0, _otherOptions.length - 1);
    final labelStyle = TextStyle(fontSize: 12, color: _w54);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Exercise name + remove
            Row(children: [
              Expanded(
                child: Text(name,
                    style: const TextStyle(
                        fontSize: 17, fontWeight: FontWeight.bold)),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 20),
                onPressed: () => _removeExercise(i),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
            ]),
            const SizedBox(height: 12),
            // Column header row
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                SizedBox(
                    width: 72, child: Text('Reps', style: labelStyle)),
                const SizedBox(width: 10),
                Expanded(child: Text('Weight', style: labelStyle)),
                const SizedBox(width: 8),
                // "Other" header with dropdown
                SizedBox(
                  width: 110,
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<int>(
                      value: selIdx,
                      isDense: true,
                      items: List.generate(
                        _otherOptions.length,
                        (idx) => DropdownMenuItem(
                          value: idx,
                          child: Text(_otherOptions[idx],
                              style: TextStyle(
                                  fontSize: 12, color: _w70)),
                        ),
                      ),
                      onChanged: (v) {
                        if (v != null) {
                          setState(() => _otherSelIdx[name] = v);
                        }
                      },
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            // Input row
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                SizedBox(
                  width: 72,
                  child: TextField(
                    controller: _repsCtrl[name],
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.center,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _weightCtrl[name],
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    textAlign: TextAlign.center,
                    decoration: InputDecoration(
                      border: const OutlineInputBorder(),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 10),
                      suffixText: _unitSel[name] ?? 'lbs',
                      suffixStyle: TextStyle(
                          fontSize: 11, color: _w38),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                // lbs / kg toggle
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: ['lbs', 'kg'].map((u) {
                    final sel = (_unitSel[name] ?? 'lbs') == u;
                    return GestureDetector(
                      onTap: () => setState(() => _unitSel[name] = u),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 3),
                        decoration: BoxDecoration(
                          color: sel
                              ? Theme.of(context).colorScheme.primary
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(u,
                            style: TextStyle(
                                fontSize: 11,
                                color: sel ? Colors.black : _w38)),
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(width: 8),
                // Other value box
                SizedBox(
                  width: 94,
                  child: TextField(
                    controller: _otherValueCtrl[name],
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    textAlign: TextAlign.center,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 8, vertical: 10),
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
    final name = ex.liftName;
    final rows = _setCtrl[name] ?? [];
    final unit = _unitSel[name] ?? 'lbs';
    final isPercent = unit == '%';
    final oneRM = isPercent ? _oneRM(name) : null;
    final otherIdx = (_otherSelIdx[name] ?? 0).clamp(0, _otherOptions.length - 1);
    final isConfirmed = _confirmed.contains(name);
    final labelStyle = TextStyle(fontSize: 11, color: _w54);

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header: name + close
            Row(children: [
              Expanded(
                child: Text(name,
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
              ),
              GestureDetector(
                onTap: () => _removeExercise(i),
                child: Icon(Icons.close, size: 20, color: _w54),
              ),
            ]),
            const SizedBox(height: 12),

            if (!isConfirmed) ...[
              // ── CONFIG PHASE ──────────────────────────────────────────────
              // Column labels
              Row(children: [
                SizedBox(width: 54, child: Text('Sets', style: labelStyle)),
                const SizedBox(width: 10),
                SizedBox(width: 54, child: Text('Reps', style: labelStyle)),
                const SizedBox(width: 10),
                // Weight label + unit dropdown inline
                Expanded(
                  child: Row(children: [
                    Text('Weight', style: labelStyle),
                    const SizedBox(width: 6),
                    DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: unit,
                        isDense: true,
                        items: ['lbs', 'kg', '%'].map((u) => DropdownMenuItem(
                          value: u,
                          child: Text(u, style: TextStyle(fontSize: 11, color: _w70)),
                        )).toList(),
                        onChanged: (v) { if (v != null) setState(() => _unitSel[name] = v); },
                      ),
                    ),
                  ]),
                ),
                const SizedBox(width: 10),
                // Other label + type dropdown
                SizedBox(
                  width: 90,
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<int>(
                      value: otherIdx,
                      isDense: true,
                      items: List.generate(_otherOptions.length, (idx) => DropdownMenuItem(
                        value: idx,
                        child: Text(_otherOptions[idx],
                            style: TextStyle(fontSize: 11, color: _w70)),
                      )),
                      onChanged: (v) { if (v != null) setState(() => _otherSelIdx[name] = v); },
                    ),
                  ),
                ),
              ]),
              const SizedBox(height: 6),
              // Input boxes row
              Row(children: [
                SizedBox(
                  width: 54,
                  child: TextField(
                    controller: _setsCountCtrl[name],
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.center,
                    decoration: const InputDecoration(
                      isDense: true, border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(vertical: 10, horizontal: 4),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  width: 54,
                  child: TextField(
                    controller: _repsCtrl[name],
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.center,
                    decoration: const InputDecoration(
                      isDense: true, border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(vertical: 10, horizontal: 4),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _weightCtrl[name],
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    textAlign: TextAlign.center,
                    decoration: InputDecoration(
                      isDense: true, border: const OutlineInputBorder(),
                      contentPadding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
                      suffixText: isPercent ? '%' : null,
                      suffixStyle: TextStyle(fontSize: 10, color: _w38),
                      helperText: isPercent && oneRM != null &&
                              double.tryParse(_weightCtrl[name]?.text.trim() ?? '') != null
                          ? '= ${(double.parse(_weightCtrl[name]!.text.trim()) / 100 * oneRM).toStringAsFixed(1)} lbs'
                          : null,
                      helperStyle: TextStyle(fontSize: 10, color: _w38),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  width: 90,
                  child: TextField(
                    controller: _otherValueCtrl[name],
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    textAlign: TextAlign.center,
                    decoration: const InputDecoration(
                      isDense: true, border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(vertical: 10, horizontal: 4),
                    ),
                  ),
                ),
              ]),
              const SizedBox(height: 14),
              Center(
                child: FilledButton(
                  onPressed: () => _confirmSets(name),
                  child: const Text('Add Sets'),
                ),
              ),
            ] else ...[
              // ── CONFIRMED PHASE ───────────────────────────────────────────
              // Column headers
              Row(children: [
                SizedBox(width: 28, child: Text('Set', style: labelStyle)),
                const SizedBox(width: 8),
                SizedBox(width: 54, child: Text('Reps', style: labelStyle)),
                const SizedBox(width: 8),
                Expanded(
                  child: Row(children: [
                    Text('Weight', style: labelStyle),
                    const SizedBox(width: 4),
                    Text(isPercent ? '%' : unit,
                        style: TextStyle(fontSize: 10, color: _w38)),
                  ]),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 54,
                  child: Text(_otherOptions[otherIdx], style: labelStyle),
                ),
                const SizedBox(width: 76),
              ]),
              const SizedBox(height: 4),
              // Set rows
              ...rows.asMap().entries.map((e) {
                final idx = e.key;
                final row = e.value;
                final pct = double.tryParse(row.weight.text.trim());
                final calcWeight = isPercent && oneRM != null && pct != null
                    ? pct / 100 * oneRM : null;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: 28,
                        child: Text('${idx + 1}',
                            style: TextStyle(
                                fontSize: 14, fontWeight: FontWeight.bold,
                                color: Theme.of(context).colorScheme.primary)),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 54,
                        child: TextField(
                          controller: row.reps,
                          keyboardType: TextInputType.number,
                          textAlign: TextAlign.center,
                          decoration: const InputDecoration(
                            isDense: true, border: OutlineInputBorder(),
                            contentPadding: EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: row.weight,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          textAlign: TextAlign.center,
                          onChanged: (_) => setState(() {}),
                          decoration: InputDecoration(
                            isDense: true, border: const OutlineInputBorder(),
                            contentPadding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                            suffixText: isPercent ? '%' : unit,
                            suffixStyle: TextStyle(fontSize: 10, color: _w38),
                            helperText: calcWeight != null
                                ? '${calcWeight.toStringAsFixed(1)} lbs' : null,
                            helperStyle: TextStyle(fontSize: 10, color: _w38),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 54,
                        child: TextField(
                          controller: row.otherValue,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          textAlign: TextAlign.center,
                          decoration: const InputDecoration(
                            isDense: true, border: OutlineInputBorder(),
                            contentPadding: EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      // Miss
                      GestureDetector(
                        onTap: () => setState(() {
                          row.status = row.status == SetStatus.missed
                              ? SetStatus.none : SetStatus.missed;
                        }),
                        child: Container(
                          width: 32, height: 32,
                          decoration: BoxDecoration(
                            color: row.status == SetStatus.missed ? Colors.red : Colors.white10,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Icon(Icons.close, size: 16,
                              color: row.status == SetStatus.missed ? Colors.white : _w38),
                        ),
                      ),
                      const SizedBox(width: 4),
                      // Success
                      GestureDetector(
                        onTap: () => setState(() {
                          row.status = row.status == SetStatus.succeeded
                              ? SetStatus.none : SetStatus.succeeded;
                        }),
                        child: Container(
                          width: 32, height: 32,
                          decoration: BoxDecoration(
                            color: row.status == SetStatus.succeeded ? Colors.green : Colors.white10,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Icon(Icons.check, size: 16,
                              color: row.status == SetStatus.succeeded ? Colors.white : _w38),
                        ),
                      ),
                    ],
                  ),
                );
              }),
              // Add / remove set buttons
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
  late List<Workout> _sortedWorkouts;

  static const _dayLabels = ['S', 'M', 'T', 'W', 'T', 'F', 'S'];
  static const _dayNames = ['Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday'];
  static const _months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];

  @override
  void initState() {
    super.initState();
    final today = _dateOnly(DateTime.now());
    final daysFromSunday = today.weekday % 7;
    _weekStart = today.subtract(Duration(days: daysFromSunday));
    _selectedDay = today;
    _refreshWorkouts();
  }

  @override
  void didUpdateWidget(_ProgramTabView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _refreshWorkouts();
  }

  void _refreshWorkouts() {
    _sortedWorkouts = widget.profile.workouts
        .where((w) => _sameDay(w.date, _selectedDay))
        .toList()
      ..sort((a, b) => b.date.compareTo(a.date));
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

  void _addExercises() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AddProgramScreen(
          date: _selectedDay,
          profile: widget.profile,
          existingDay: _dayData(_selectedDay),
          onSaved: (day) {
            setState(() {
              widget.profile.program.removeWhere(
                  (d) => d.date.year == _selectedDay.year &&
                      d.date.month == _selectedDay.month &&
                      d.date.day == _selectedDay.day);
              widget.profile.program.add(day);
            });
            widget.onChanged();
          },
          onWorkoutLogged: widget.onChanged,
        ),
      ),
    );
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
                onTap: () => setState(() {
                  _selectedDay = day;
                  _refreshWorkouts();
                }),
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
                          color: isSelected ? primary : _w54,
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
                              color: isSelected ? Colors.white : _w70,
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
              // Programmed exercises — shown as a single card
              if (dayData == null || exercises.isEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Text('No program for this day.',
                        style: TextStyle(color: _w54, fontSize: 13)),
                  ),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  sliver: SliverToBoxAdapter(
                    child: Dismissible(
                      key: Key('prog_${_selectedDay.toIso8601String()}'),
                      direction: DismissDirection.endToStart,
                      background: _dismissBackground(),
                      onDismissed: (_) {
                        setState(() {
                          widget.profile.program.remove(dayData);
                        });
                        widget.onChanged();
                      },
                      child: Card(
                        child: InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => AddProgramScreen(
                                date: _selectedDay,
                                profile: widget.profile,
                                existingDay: dayData,
                                onSaved: (updatedDay) {
                                  setState(() {
                                    widget.profile.program.removeWhere(
                                        (d) => d.date.year == updatedDay.date.year &&
                                            d.date.month == updatedDay.date.month &&
                                            d.date.day == updatedDay.date.day);
                                    widget.profile.program.add(updatedDay);
                                  });
                                  widget.onChanged();
                                },
                                onWorkoutLogged: widget.onChanged,
                              ),
                            ),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(children: [
                                  Icon(
                                    dayData.completed ? Icons.check_circle : Icons.view_list_outlined,
                                    size: 16,
                                    color: dayData.completed
                                        ? Colors.green.shade400
                                        : Theme.of(context).colorScheme.primary,
                                  ),
                                  const SizedBox(width: 8),
                                  const Text('Program',
                                      style: TextStyle(
                                          fontSize: 15, fontWeight: FontWeight.bold)),
                                  if (dayData.completed) ...[
                                    const SizedBox(width: 8),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: Colors.green.shade900.withValues(alpha: 0.5),
                                        borderRadius: BorderRadius.circular(10),
                                        border: Border.all(color: Colors.green.shade800),
                                      ),
                                      child: Text('Completed',
                                          style: TextStyle(fontSize: 11, color: Colors.green.shade400,
                                              fontWeight: FontWeight.w600)),
                                    ),
                                  ],
                                  const Spacer(),
                                  Icon(Icons.chevron_right, color: _w38),
                                ]),
                                const SizedBox(height: 10),
                                ...[
                                  ('Warm Up', exercises.where((e) => e.block == 'warmUp').toList()),
                                  ('Main', exercises.where((e) => e.block == 'main').toList()),
                                  ('Cool Down', exercises.where((e) => e.block == 'coolDown').toList()),
                                ].where((b) => b.$2.isNotEmpty).map((b) => Padding(
                                  padding: const EdgeInsets.only(bottom: 6),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(b.$1,
                                          style: TextStyle(
                                              fontSize: 12,
                                              fontWeight: FontWeight.w600,
                                              color: _w54)),
                                      const SizedBox(height: 3),
                                      Wrap(
                                        spacing: 6,
                                        runSpacing: 4,
                                        children: b.$2
                                            .map((ex) => Container(
                                                  padding: const EdgeInsets.symmetric(
                                                      horizontal: 8, vertical: 3),
                                                  decoration: BoxDecoration(
                                                    color: ex.completed
                                                        ? Colors.green.shade900.withValues(alpha: 0.4)
                                                        : Theme.of(context)
                                                            .colorScheme
                                                            .primaryContainer
                                                            .withValues(alpha: 0.3),
                                                    borderRadius: BorderRadius.circular(6),
                                                    border: ex.completed
                                                        ? Border.all(color: Colors.green.shade800)
                                                        : null,
                                                  ),
                                                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                                                    if (ex.completed) ...[
                                                      Icon(Icons.check, size: 11, color: Colors.green.shade400),
                                                      const SizedBox(width: 3),
                                                    ],
                                                    Text(ex.name,
                                                        style: TextStyle(
                                                            fontSize: 12,
                                                            color: ex.completed ? Colors.green.shade300 : null)),
                                                  ]),
                                                ))
                                            .toList(),
                                      ),
                                    ],
                                  ),
                                )),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              // Workouts header
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Row(children: [
                    Icon(Icons.fitness_center, size: 15,
                        color: Theme.of(context).colorScheme.primary),
                    const SizedBox(width: 6),
                    const Text('Workouts',
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                  ]),
                ),
              ),
              // Workouts list (planned + completed)
              if (_sortedWorkouts.isEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: Text('No workouts logged yet.',
                        style: TextStyle(color: _w54, fontSize: 13)),
                  ),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  sliver: SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (_, i) {
                        final workout = _sortedWorkouts[i];
                        final exNames = workout.exercises.map((e) => e.liftName).join(' · ');
                        final isPlanned = !workout.completed;
                        return Dismissible(
                          key: Key('workout_${workout.hashCode}_${workout.date.toIso8601String()}'),
                          direction: DismissDirection.endToStart,
                          background: _dismissBackground(),
                          onDismissed: (_) {
                            setState(() {
                              widget.profile.workouts.remove(workout);
                              _refreshWorkouts();
                            });
                            widget.onChanged();
                          },
                          child: Card(
                            margin: const EdgeInsets.only(bottom: 8),
                            shape: isPlanned
                                ? RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                    side: BorderSide(
                                      color: Theme.of(context).colorScheme.primary,
                                      width: 1.5,
                                    ),
                                  )
                                : null,
                            color: isPlanned
                                ? Theme.of(context).colorScheme.surface
                                : null,
                            child: ListTile(
                              contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 6),
                              title: Row(children: [
                                if (isPlanned) ...[
                                  Icon(Icons.pending_outlined, size: 14,
                                      color: Theme.of(context).colorScheme.primary),
                                  const SizedBox(width: 6),
                                ] else if (workout.completed) ...[
                                  Icon(Icons.check_circle, size: 14,
                                      color: Colors.green.shade400),
                                  const SizedBox(width: 6),
                                ],
                                Expanded(
                                  child: Text(_fmtDate(workout.date),
                                      style: TextStyle(
                                          fontWeight: FontWeight.w600,
                                          fontSize: 15,
                                          color: isPlanned ? _w70 : Colors.white)),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: isPlanned
                                        ? Colors.transparent
                                        : Theme.of(context).colorScheme.primaryContainer,
                                    borderRadius: BorderRadius.circular(6),
                                    border: isPlanned
                                        ? Border.all(
                                            color: Theme.of(context).colorScheme.primary,
                                            width: 1)
                                        : null,
                                  ),
                                  child: Text(
                                    isPlanned ? 'Planned' : workout.type.label,
                                    style: TextStyle(
                                        fontSize: 10,
                                        color: isPlanned
                                            ? Theme.of(context).colorScheme.primary
                                            : Theme.of(context).colorScheme.onPrimaryContainer),
                                  ),
                                ),
                              ]),
                              subtitle: Text(
                                  exNames.isEmpty ? 'No exercises' : exNames,
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: isPlanned ? _w38 : _w60),
                                  overflow: TextOverflow.ellipsis),
                              trailing: Icon(
                                isPlanned ? Icons.play_circle_outline : Icons.chevron_right,
                                color: isPlanned
                                    ? Theme.of(context).colorScheme.primary
                                    : _w54,
                              ),
                              onTap: () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => isPlanned
                                      ? WorkoutScreen(
                                          profile: widget.profile,
                                          editingWorkout: workout,
                                          onSaved: () {
                                            setState(() => _refreshWorkouts());
                                            widget.onChanged();
                                          },
                                        )
                                      : WorkoutDetailScreen(
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
                      childCount: _sortedWorkouts.length,
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
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => WorkoutScreen(
                        profile: widget.profile,
                        onSaved: () {
                          setState(() => _refreshWorkouts());
                          widget.onChanged();
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ─── Program Section Item (strength exercise or EMOM/AMRAP group) ────────────

class _ProgGroup {
  static int _counter = 0;
  final String id = 'g_${_counter++}';
  final String type; // 'emom' or 'amrap'
  final List<ProgramExercise> exercises;
  final TextEditingController intervalMinCtrl;
  final TextEditingController intervalSecCtrl;
  final TextEditingController totalSetsCtrl; // EMOM: total intervals; AMRAP: time cap

  // Per-exercise controllers
  final Map<ProgramExercise, TextEditingController> nameCtrl = {};
  final Map<ProgramExercise, TextEditingController> repsCtrl = {};
  final Map<ProgramExercise, TextEditingController> weightCtrl = {};
  final Map<ProgramExercise, TextEditingController> rpeCtrl = {};
  final Map<ProgramExercise, String> repOrTimeMode = {}; // 'reps' or 'time' per exercise

  // Per-set controllers for single-exercise EMOM (one controller per set/minute)
  final Map<ProgramExercise, List<TextEditingController>> perSetRepsCtrl = {};
  final Map<ProgramExercise, List<TextEditingController>> perSetWeightCtrl = {};
  final Map<ProgramExercise, List<TextEditingController>> perSetRpeCtrl = {};

  final TextEditingController workingMaxCtrl; // emomStrength only

  // Per-exercise percent controllers (emomStrength multi-exercise)
  final Map<ProgramExercise, TextEditingController> pctCtrl = {};
  // Per-set percent controllers (emomStrength single-exercise)
  final Map<ProgramExercise, List<TextEditingController>> perSetPctCtrl = {};
  // Per-set status (emomStrength single-exercise)
  final Map<ProgramExercise, List<SetStatus>> perSetStatus = {};

  _ProgGroup({
    required this.type,
    required this.exercises,
    String intervalMin = '1',
    String intervalSec = '0',
    String totalSets = '6',
    String workingMax = '',
  })  : intervalMinCtrl = TextEditingController(text: intervalMin),
        intervalSecCtrl = TextEditingController(text: intervalSec),
        totalSetsCtrl = TextEditingController(text: totalSets),
        workingMaxCtrl = TextEditingController(text: workingMax) {
    for (final ex in exercises) { _initExCtrl(ex); }
  }

  void _initExCtrl(ProgramExercise ex) {
    nameCtrl[ex] = TextEditingController(text: ex.name);
    pctCtrl[ex] = TextEditingController();
    repOrTimeMode[ex] = 'reps';
    repsCtrl[ex] = TextEditingController(
        text: ex.sets.isNotEmpty ? ex.sets.first.reps.toString() : '10');
    weightCtrl[ex] = TextEditingController(
        text: ex.sets.isNotEmpty && ex.sets.first.weight != null
            ? ex.sets.first.weight!.toInt().toString()
            : '');
    rpeCtrl[ex] = TextEditingController(
        text: ex.sets.isNotEmpty && ex.sets.first.rpe != null
            ? ex.sets.first.rpe!.toStringAsFixed(1)
            : '');
  }

  void addExercise(ProgramExercise ex) {
    exercises.add(ex);
    _initExCtrl(ex);
  }

  /// Grows or shrinks per-set controller lists to [count] for single-exercise EMOM.
  void syncSetControllers(ProgramExercise ex, int count) {
    final rList = perSetRepsCtrl.putIfAbsent(ex, () => []);
    final wList = perSetWeightCtrl.putIfAbsent(ex, () => []);
    final eList = perSetRpeCtrl.putIfAbsent(ex, () => []);
    final pList = perSetPctCtrl.putIfAbsent(ex, () => []);
    final sList = perSetStatus.putIfAbsent(ex, () => []);
    while (rList.length < count) {
      rList.add(TextEditingController(text: repsCtrl[ex]?.text ?? '10'));
      wList.add(TextEditingController(text: weightCtrl[ex]?.text ?? ''));
      eList.add(TextEditingController());
      pList.add(TextEditingController());
      sList.add(SetStatus.none);
    }
    while (rList.length > count) {
      rList.removeLast().dispose();
      wList.removeLast().dispose();
      eList.removeLast().dispose();
      pList.removeLast().dispose();
      sList.removeLast();
    }
  }

  void flush() {
    final intervalMin = int.tryParse(intervalMinCtrl.text) ?? 1;
    final intervalSec = int.tryParse(intervalSecCtrl.text) ?? 0;
    final totalSets = int.tryParse(totalSetsCtrl.text) ?? 6;
    final workingMax = double.tryParse(workingMaxCtrl.text);
    final isSingleExEmom = (type == 'emom' || type == 'emomStrength') && exercises.length == 1;
    for (final ex in exercises) {
      final isTime = repOrTimeMode[ex] == 'time';
      final nameText = nameCtrl[ex]?.text.trim() ?? '';
      if (nameText.isNotEmpty) ex.name = nameText;
      ex.groupWorkingMax = workingMax;
      if (isSingleExEmom && perSetRepsCtrl[ex] != null && perSetRepsCtrl[ex]!.isNotEmpty) {
        ex.sets = List.generate(perSetRepsCtrl[ex]!.length, (i) => ProgramSet(
          reps: int.tryParse(perSetRepsCtrl[ex]![i].text) ?? 10,
          weight: isTime ? null : double.tryParse(perSetWeightCtrl[ex]![i].text),
          unit: 'lbs',
          rpe: isTime ? double.tryParse(perSetRpeCtrl[ex]![i].text) : null,
          pct: double.tryParse(perSetPctCtrl[ex]?[i].text ?? ''),
        ));
      } else {
        ex.sets = [
          ProgramSet(
            reps: int.tryParse(repsCtrl[ex]?.text ?? '10') ?? 10,
            weight: isTime ? null : double.tryParse(weightCtrl[ex]?.text ?? ''),
            unit: 'lbs',
            rpe: isTime ? double.tryParse(rpeCtrl[ex]?.text ?? '') : null,
          )
        ];
      }
      ex.groupType = type;
      ex.groupIntervalMin = intervalMin;
      ex.groupIntervalSec = intervalSec;
      ex.groupTotalSets = totalSets;
    }
  }

  void dispose() {
    intervalMinCtrl.dispose();
    intervalSecCtrl.dispose();
    totalSetsCtrl.dispose();
    workingMaxCtrl.dispose();
    for (final c in nameCtrl.values) { c.dispose(); }
    for (final c in pctCtrl.values) { c.dispose(); }
    for (final c in repsCtrl.values) { c.dispose(); }
    for (final c in weightCtrl.values) { c.dispose(); }
    for (final c in rpeCtrl.values) { c.dispose(); }
    for (final list in perSetRepsCtrl.values) { for (final c in list) { c.dispose(); } }
    for (final list in perSetWeightCtrl.values) { for (final c in list) { c.dispose(); } }
    for (final list in perSetRpeCtrl.values) { for (final c in list) { c.dispose(); } }
    for (final list in perSetPctCtrl.values) { for (final c in list) { c.dispose(); } }
  }
}

class _SectionItem {
  final ProgramExercise? ex;
  final _ProgGroup? group;
  _SectionItem.exercise(ProgramExercise e) : ex = e, group = null;
  _SectionItem.group(_ProgGroup g) : ex = null, group = g;
  bool get isGroup => group != null;
  Object get key => isGroup ? group!.id : ex!;
}

// ─── Add Program Screen ───────────────────────────────────────────────────────

class AddProgramScreen extends StatefulWidget {
  final DateTime date;
  final Profile profile;
  final ProgramDay? existingDay;
  final void Function(ProgramDay) onSaved;
  final VoidCallback? onWorkoutLogged;

  const AddProgramScreen({
    super.key,
    required this.date,
    required this.profile,
    required this.existingDay,
    required this.onSaved,
    this.onWorkoutLogged,
  });

  @override
  State<AddProgramScreen> createState() => _AddProgramScreenState();
}

class _AddProgramScreenState extends State<AddProgramScreen> {
  // Each section holds _SectionItem (solo exercise or EMOM/AMRAP group)
  late final List<_SectionItem> _warmUp;
  late final List<_SectionItem> _main;
  late final List<_SectionItem> _coolDown;

  // Controllers for solo strength exercises
  final Map<ProgramExercise, List<_ProgSetRow>> _rowCtrl = {};
  final Map<ProgramExercise, String> _unitSel = {};

  late final TextEditingController _notesCtrl;
  late bool _editMode;
  late List<ProgramExercise> _outlineExercises;

  static const _months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];

  @override
  void initState() {
    super.initState();
    _editMode = widget.existingDay == null;
    _notesCtrl = TextEditingController(text: widget.existingDay?.notes ?? '');
    _outlineExercises = widget.existingDay?.exercises ?? [];
    final existing = _outlineExercises;
    _warmUp   = _parseSection(existing, 'warmUp');
    _main     = _parseSection(existing, 'main');
    _coolDown = _parseSection(existing, 'coolDown');
  }

  /// Reconstruct _SectionItem list from flat ProgramExercise list for one section.
  List<_SectionItem> _parseSection(List<ProgramExercise> all, String section) {
    final filtered = all.where((e) =>
        e.block == section ||
        (section == 'main' && e.block != 'warmUp' && e.block != 'coolDown')).toList();
    final items = <_SectionItem>[];
    final seenGroups = <String>{};
    for (final ex in filtered) {
      if (ex.groupId == null) {
        _initCtrl(ex);
        items.add(_SectionItem.exercise(ex));
      } else if (!seenGroups.contains(ex.groupId)) {
        seenGroups.add(ex.groupId!);
        final groupExes = filtered.where((e) => e.groupId == ex.groupId).toList();
        final group = _ProgGroup(
          type: ex.groupType ?? 'emom',
          exercises: groupExes,
          intervalMin: (ex.groupIntervalMin ?? 1).toString(),
          intervalSec: (ex.groupIntervalSec ?? 0).toString(),
          totalSets: (ex.groupTotalSets ?? 6).toString(),
          workingMax: ex.groupWorkingMax != null ? ex.groupWorkingMax!.toStringAsFixed(0) : '',
        );
        items.add(_SectionItem.group(group));
      }
    }
    return items;
  }

  @override
  void dispose() {
    _notesCtrl.dispose();
    for (final rows in _rowCtrl.values) { for (final r in rows) { r.dispose(); } }
    // dispose group controllers (collected from all sections)
    for (final item in [..._warmUp, ..._main, ..._coolDown]) {
      item.group?.dispose();
    }
    super.dispose();
  }

  void _initCtrl(ProgramExercise ex) {
    _unitSel[ex] = ex.sets.isNotEmpty ? ex.sets.first.unit : 'lbs';
    _rowCtrl[ex] = ex.sets.isNotEmpty
        ? ex.sets.map((s) => _ProgSetRow.fromProgramSet(s)).toList()
        : [_ProgSetRow(), _ProgSetRow(), _ProgSetRow()];
  }

  void _disposeCtrl(ProgramExercise ex) {
    for (final r in _rowCtrl[ex] ?? []) { r.dispose(); }
    _rowCtrl.remove(ex);
    _unitSel.remove(ex);
  }

  // Flatten all section items back to a List of ProgramExercise for saving.
  List<ProgramExercise> _flattenSection(List<_SectionItem> items, String blockKey) {
    final result = <ProgramExercise>[];
    for (final item in items) {
      if (item.ex != null) {
        final ex = item.ex!;
        ex.block = blockKey;
        ex.groupId = null;
        ex.groupType = null;
        ex.sets = (_rowCtrl[ex] ?? []).map((r) => ProgramSet(
          reps: int.tryParse(r.reps.text) ?? 5,
          weight: double.tryParse(r.weight.text),
          unit: _unitSel[ex] ?? 'lbs',
          rpe: double.tryParse(r.rpe.text),
          status: r.status,
        )).toList();
        result.add(ex);
      } else if (item.group != null) {
        final g = item.group!;
        g.flush();
        for (final ex in g.exercises) {
          ex.block = blockKey;
          ex.groupId = g.id;
          result.add(ex);
        }
      }
    }
    return result;
  }

  String get _dateLabel {
    final d = widget.date;
    const days = ['Sun','Mon','Tue','Wed','Thu','Fri','Sat'];
    return '${days[d.weekday % 7]}, ${_months[d.month - 1]} ${d.day}';
  }


  List<ProgramExercise> _buildExerciseList() => [
    ..._flattenSection(_warmUp, 'warmUp'),
    ..._flattenSection(_main, 'main'),
    ..._flattenSection(_coolDown, 'coolDown'),
  ];

  void _persistWorkout(List<ProgramExercise> exercises, {required bool completed, String? notes}) {
    notes ??= _notesCtrl.text.trim().isEmpty ? null : _notesCtrl.text.trim();
    widget.onSaved(ProgramDay(
      date: widget.date,
      exercises: exercises,
      completed: completed,
      notes: notes,
    ));
    widget.onWorkoutLogged?.call();
  }

  void _save() {
    final exercises = _buildExerciseList();
    _persistWorkout(exercises, completed: false);
    setState(() {
      _outlineExercises = exercises;
      _editMode = false;
    });
  }

  void _startWorkout() {
    final exercises = _buildExerciseList();
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => ProgramFlowScreen(
        exercises: exercises,
        dateLabel: _dateLabel,
        onCompleted: (String? notes) {
          final n = notes?.trim().isEmpty == true ? null : notes?.trim();
          // Use captured 'exercises' directly — do NOT call _buildExerciseList() here,
          // as flush() would overwrite the actual workout data with planned values.
          _persistWorkout(exercises, completed: true, notes: n);
          if (mounted) setState(() => _outlineExercises = List.of(exercises));
        },
      ),
    ));
  }

  // ── Exercise picker (Strength / EMOM / AMRAP) ─────────────────────────────

  Future<Set<String>> _showExercisePicker({required Set<String> exclude}) async {
    Set<String> result = {};
    await showDialog(
      context: context,
      builder: (_) => _ExercisePickerDialog(
        existingLifts: widget.profile.lifts,
        alreadyAdded: exclude,
        onConfirm: (names, newNames) {
          for (final n in newNames) {
            if (!widget.profile.lifts.any((l) => l.name == n)) {
              widget.profile.lifts.add(Lift(name: n));
            }
          }
          if (newNames.isNotEmpty) widget.onWorkoutLogged?.call();
          result = names.toSet();
        },
      ),
    );
    return result;
  }

  Future<void> _addStrength(String blockKey, List<_SectionItem> section) async {
    final existing = section.where((i) => i.ex != null).map((i) => i.ex!.name).toSet();
    final selected = await _showExercisePicker(exclude: existing);
    if (selected.isEmpty) return;
    setState(() {
      for (final name in selected) {
        final ex = ProgramExercise(name: name, block: blockKey);
        _initCtrl(ex);
        section.add(_SectionItem.exercise(ex));
      }
    });
  }

  Future<void> _addGroupWorkout(String type, String blockKey, List<_SectionItem> section) async {
    final selected = await _showExercisePicker(exclude: {});
    if (selected.isEmpty || !mounted) return;

    // Show config dialog (min/sets for EMOM/EMOM Strength, time cap for AMRAP, rounds for For Rounds, minutes for For Time)
    final isEmomType = type == 'emom' || type == 'emomStrength';
    final isForRounds = type == 'forRounds';
    final isForTime = type == 'forTime';
    final configCtrl1 = TextEditingController(text: isEmomType ? '1' : isForRounds ? '3' : isForTime ? '20' : '20');
    final configCtrlSec = TextEditingController(text: '0');
    final configCtrl2 = TextEditingController(text: '6');
    bool confirmed = false;

    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isEmomType ? 'EMOM Config' : isForRounds ? 'For Rounds Config' : isForTime ? 'For Time Config' : 'AMRAP Config'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Show selected exercises
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: selected.map((s) => Chip(
                label: Text(s, style: const TextStyle(fontSize: 12)),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              )).toList(),
            ),
            const SizedBox(height: 16),
            if (isEmomType) ...[
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: configCtrl1,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Min',
                      border: OutlineInputBorder(),
                      suffixText: 'min',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: configCtrlSec,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Sec',
                      border: OutlineInputBorder(),
                      suffixText: 'sec',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: configCtrl2,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Total sets',
                      border: OutlineInputBorder(),
                      hintText: 'e.g. 6',
                    ),
                  ),
                ),
              ]),
              const SizedBox(height: 8),
              // Preview
              Builder(builder: (ctx) {
                final exList = selected.toList();
                final totalSets = int.tryParse(configCtrl2.text) ?? 6;
                final minPer = int.tryParse(configCtrl1.text) ?? 1;
                final secPer = int.tryParse(configCtrlSec.text) ?? 0;
                final intervalLabel = secPer > 0 ? '$minPer:${secPer.toString().padLeft(2, '0')}' : '$minPer';
                final lines = List.generate(totalSets, (i) {
                  final exName = exList[i % exList.length];
                  return 'Min ${i + 1}: $exName';
                });
                return Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.white10,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Preview (E${intervalLabel}MOM)',
                          style: TextStyle(fontSize: 11, color: _w54)),
                      const SizedBox(height: 4),
                      ...lines.map((l) => Text(l,
                          style: TextStyle(fontSize: 12, color: _w70))),
                    ],
                  ),
                );
              }),
            ] else if (isForRounds) ...[
              TextField(
                controller: configCtrl1,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Rounds',
                  border: OutlineInputBorder(),
                  suffixText: 'rounds',
                ),
              ),
            ] else if (isForTime) ...[
              TextField(
                controller: configCtrl1,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Time Cap',
                  border: OutlineInputBorder(),
                  suffixText: 'min',
                ),
              ),
            ] else ...[
              TextField(
                controller: configCtrl1,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Time cap',
                  border: OutlineInputBorder(),
                  suffixText: 'min',
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () { confirmed = true; Navigator.pop(ctx); },
            child: const Text('Add'),
          ),
        ],
      ),
    );

    configCtrl1.dispose();
    configCtrlSec.dispose();
    configCtrl2.dispose();

    if (!confirmed) return;
    setState(() {
      final exercises = selected.map((name) => ProgramExercise(
        name: name, block: blockKey, sets: [ProgramSet(reps: 10)],
      )).toList();
      final group = _ProgGroup(
        type: type,
        exercises: exercises,
        intervalMin: configCtrl1.text,
        intervalSec: configCtrlSec.text,
        totalSets: configCtrl2.text,
      );
      section.add(_SectionItem.group(group));
    });
  }

  void _showAddMenu(String blockKey, List<_SectionItem> section) {
    showModalBottomSheet(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.fitness_center),
              title: const Text('Strength'),
              subtitle: const Text('Sets × Reps with weight tracking'),
              onTap: () { Navigator.pop(context); _addStrength(blockKey, section); },
            ),
            ListTile(
              leading: const Icon(Icons.timer_outlined),
              title: const Text('EMOM'),
              subtitle: const Text('Every Minute On the Minute'),
              onTap: () { Navigator.pop(context); _addGroupWorkout('emom', blockKey, section); },
            ),
            ListTile(
              leading: const Icon(Icons.fitness_center),
              title: const Text('EMOM (Strength)'),
              subtitle: const Text('EMOM with % of working max'),
              onTap: () { Navigator.pop(context); _addGroupWorkout('emomStrength', blockKey, section); },
            ),
            ListTile(
              leading: const Icon(Icons.loop),
              title: const Text('AMRAP'),
              subtitle: const Text('As Many Rounds As Possible'),
              onTap: () { Navigator.pop(context); _addGroupWorkout('amrap', blockKey, section); },
            ),
            ListTile(
              leading: const Icon(Icons.repeat),
              title: const Text('For Rounds'),
              subtitle: const Text('Fixed number of rounds'),
              onTap: () { Navigator.pop(context); _addGroupWorkout('forRounds', blockKey, section); },
            ),
            ListTile(
              leading: const Icon(Icons.timer_outlined),
              title: const Text('For Time'),
              subtitle: const Text('Complete for time (minute cap)'),
              onTap: () { Navigator.pop(context); _addGroupWorkout('forTime', blockKey, section); },
            ),
          ],
        ),
      ),
    );
  }

  // ── Card builders ─────────────────────────────────────────────────────────

  Widget _groupStatusBtnPair(_ProgGroup group, ProgramExercise ex, int idx) {
    final locked = ex.completed;
    final sList = group.perSetStatus.putIfAbsent(ex, () => List.filled(group.perSetRepsCtrl[ex]?.length ?? 0, SetStatus.none));
    while (sList.length <= idx) { sList.add(SetStatus.none); }
    final status = sList[idx];
    return _buildStatusPair(
      locked: locked,
      status: status,
      onMissed: () => setState(() { sList[idx] = status == SetStatus.missed ? SetStatus.none : SetStatus.missed; }),
      onSucceeded: () => setState(() { sList[idx] = status == SetStatus.succeeded ? SetStatus.none : SetStatus.succeeded; }),
    );
  }

  Widget _statusBtnPair(ProgramExercise ex, int idx) {
    final locked = ex.completed;
    final row = _rowCtrl[ex]![idx];
    final status = row.status;
    return _buildStatusPair(
      locked: locked,
      status: status,
      onMissed: () => setState(() { row.status = status == SetStatus.missed ? SetStatus.none : SetStatus.missed; }),
      onSucceeded: () => setState(() { row.status = status == SetStatus.succeeded ? SetStatus.none : SetStatus.succeeded; }),
    );
  }

  Widget _buildStatusPair({
    required bool locked,
    required SetStatus status,
    required VoidCallback onMissed,
    required VoidCallback onSucceeded,
  }) {
    Widget btn(IconData icon, Color activeColor, bool active, VoidCallback onTap) =>
        GestureDetector(
          onTap: locked ? null : onTap,
          child: Container(
            width: 32, height: 32,
            decoration: BoxDecoration(
              color: active ? activeColor : Colors.white10,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(icon, size: 16, color: active ? Colors.white : _w38),
          ),
        );

    if (locked) {
      if (status == SetStatus.missed) {
        return Row(mainAxisSize: MainAxisSize.min, children: [
          btn(Icons.close, Colors.red, true, onMissed),
          const SizedBox(width: 36),
        ]);
      }
      if (status == SetStatus.succeeded) {
        return Row(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(width: 36),
          btn(Icons.check, Colors.green, true, onSucceeded),
        ]);
      }
      return const SizedBox(width: 68);
    }

    return Row(mainAxisSize: MainAxisSize.min, children: [
      btn(Icons.close, Colors.red, status == SetStatus.missed, onMissed),
      const SizedBox(width: 4),
      btn(Icons.check, Colors.green, status == SetStatus.succeeded, onSucceeded),
    ]);
  }

  Widget _buildExerciseCard(ProgramExercise ex, List<_SectionItem> section, int itemIdx) {
    final rows = _rowCtrl[ex] ?? [];
    final unit = _unitSel[ex] ?? 'lbs';
    return Card(
      key: ObjectKey(ex),
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              ReorderableDragStartListener(
                index: itemIdx,
                child: Icon(Icons.drag_handle, color: _w38, size: 22),
              ),
              const SizedBox(width: 8),
              Expanded(child: Text(ex.name,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold))),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'lbs', label: Text('lbs')),
                  ButtonSegment(value: 'kg', label: Text('kg')),
                ],
                selected: {unit},
                onSelectionChanged: (s) => setState(() => _unitSel[ex] = s.first),
                style: const ButtonStyle(
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: () => setState(() { section.removeAt(itemIdx); _disposeCtrl(ex); }),
                child: Icon(Icons.close, size: 18, color: _w38),
              ),
            ]),
            const SizedBox(height: 10),
            Row(children: [
              SizedBox(width: 24, child: Text('Set', style: TextStyle(fontSize: 11, color: _w38))),
              SizedBox(width: 8),
              SizedBox(width: 56, child: Text('Reps', style: TextStyle(fontSize: 11, color: _w38))),
              SizedBox(width: 8),
              Expanded(child: Text('Weight', style: TextStyle(fontSize: 11, color: _w38))),
              SizedBox(width: 8),
              SizedBox(width: 48, child: Text('RPE', style: TextStyle(fontSize: 11, color: _w38), textAlign: TextAlign.center)),
              SizedBox(width: 76),
            ]),
            const SizedBox(height: 4),
            ...rows.asMap().entries.map((e) {
              final rowIdx = e.key; final row = e.value;
              return Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                  SizedBox(width: 24, child: Text('${rowIdx + 1}',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold,
                          color: Theme.of(context).colorScheme.primary))),
                  const SizedBox(width: 8),
                  SizedBox(width: 56, child: TextField(
                    controller: row.reps, keyboardType: TextInputType.number,
                    textAlign: TextAlign.center,
                    onChanged: (v) {
                      for (int j = rowIdx + 1; j < rows.length; j++) {
                        rows[j].reps.value = TextEditingValue(text: v, selection: TextSelection.collapsed(offset: v.length));
                      }
                    },
                    decoration: const InputDecoration(isDense: true, border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(vertical: 7, horizontal: 4)),
                  )),
                  const SizedBox(width: 8),
                  Expanded(child: TextField(
                    controller: row.weight,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    textAlign: TextAlign.center,
                    onChanged: (v) {
                      for (int j = rowIdx + 1; j < rows.length; j++) {
                        rows[j].weight.value = TextEditingValue(text: v, selection: TextSelection.collapsed(offset: v.length));
                      }
                    },
                    decoration: const InputDecoration(isDense: true, border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(vertical: 7, horizontal: 4)),
                  )),
                  const SizedBox(width: 8),
                  SizedBox(width: 48, child: TextField(
                    controller: row.rpe,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    textAlign: TextAlign.center,
                    onChanged: (v) {
                      for (int j = rowIdx + 1; j < rows.length; j++) {
                        rows[j].rpe.value = TextEditingValue(text: v, selection: TextSelection.collapsed(offset: v.length));
                      }
                    },
                    decoration: const InputDecoration(isDense: true, border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(vertical: 7, horizontal: 4), hintText: '–'),
                  )),
                  const SizedBox(width: 6),
                  _statusBtnPair(ex, rowIdx),
                ]),
              );
            }),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              IconButton(
                icon: const Icon(Icons.add_circle_outline, size: 20),
                onPressed: () => setState(() {
                  final prev = rows.isNotEmpty ? rows.last : null;
                  rows.add(_ProgSetRow(reps: prev?.reps.text ?? '5',
                      weight: prev?.weight.text ?? '', rpe: prev?.rpe.text ?? ''));
                }),
                padding: EdgeInsets.zero, constraints: const BoxConstraints(),
                visualDensity: VisualDensity.compact,
              ),
              const SizedBox(width: 20),
              IconButton(
                icon: const Icon(Icons.remove_circle_outline, size: 20),
                onPressed: rows.isEmpty ? null : () => setState(() => rows.removeLast().dispose()),
                padding: EdgeInsets.zero, constraints: const BoxConstraints(),
                visualDensity: VisualDensity.compact,
              ),
            ]),
            const SizedBox(height: 8),
            // Mark Done / Done button
            ex.completed
                ? Row(children: [
                    Icon(Icons.check_circle, color: Colors.green.shade400, size: 18),
                    const SizedBox(width: 6),
                    Text('Completed', style: TextStyle(color: Colors.green.shade400, fontWeight: FontWeight.w600)),
                    const Spacer(),
                    TextButton(
                      onPressed: () => setState(() => ex.completed = false),
                      style: TextButton.styleFrom(padding: EdgeInsets.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                      child: Text('Undo', style: TextStyle(fontSize: 12, color: _w38)),
                    ),
                  ])
                : SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () => setState(() => ex.completed = true),
                      icon: const Icon(Icons.check, size: 16),
                      label: const Text('Mark Done'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.green.shade400,
                        side: BorderSide(color: Colors.green.shade700),
                        padding: const EdgeInsets.symmetric(vertical: 8),
                      ),
                    ),
                  ),
          ],
        ),
      ),
    );
  }

  Widget _buildGroupCard(_ProgGroup group, List<_SectionItem> section, int itemIdx) {
    final isEmom = group.type == 'emom' || group.type == 'emomStrength';
    final isEmomStrength = group.type == 'emomStrength';
    final exList = group.exercises;
    final totalSets = int.tryParse(group.totalSetsCtrl.text) ?? 6;
    final isSingleExEmom = isEmom && exList.length == 1;
    final workingMax = double.tryParse(group.workingMaxCtrl.text) ?? 0;
    final isForRounds = group.type == 'forRounds';
    final isForTime = group.type == 'forTime';
    final typeColor = isEmomStrength ? Colors.deepPurple : isEmom ? Colors.orange : isForRounds ? Colors.indigo : isForTime ? Colors.cyan.shade700 : Colors.teal;
    return Card(
      key: ValueKey(group.id),
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: typeColor.withValues(alpha: 0.6), width: 1.5),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(children: [
              ReorderableDragStartListener(
                index: itemIdx,
                child: Icon(Icons.drag_handle, color: _w38, size: 22),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: typeColor.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(isEmomStrength ? 'EMOM (Strength)' : isEmom ? 'EMOM' : isForRounds ? 'For Rounds' : isForTime ? 'For Time' : 'AMRAP',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: typeColor)),
              ),
              const Spacer(),
              GestureDetector(
                onTap: () => setState(() { group.dispose(); section.removeAt(itemIdx); }),
                child: Icon(Icons.close, size: 18, color: _w38),
              ),
            ]),
            const SizedBox(height: 12),
            // Config row
            if (isEmom)
              Column(
                children: [
                  Row(children: [
                    Expanded(child: TextField(
                      controller: group.intervalMinCtrl,
                      keyboardType: TextInputType.number,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        labelText: 'Min',
                        border: OutlineInputBorder(), isDense: true, suffixText: 'min',
                      ),
                    )),
                    const SizedBox(width: 8),
                    Expanded(child: TextField(
                      controller: group.intervalSecCtrl,
                      keyboardType: TextInputType.number,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        labelText: 'Sec',
                        border: OutlineInputBorder(), isDense: true, suffixText: 'sec',
                      ),
                    )),
                    const SizedBox(width: 8),
                    Expanded(child: TextField(
                      controller: group.totalSetsCtrl,
                      keyboardType: TextInputType.number,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        labelText: 'Total sets',
                        border: OutlineInputBorder(), isDense: true,
                      ),
                    )),
                  ]),
                  if (isEmomStrength) ...[
                    const SizedBox(height: 10),
                    TextField(
                      controller: group.workingMaxCtrl,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        labelText: 'Working Max',
                        border: OutlineInputBorder(), isDense: true, suffixText: 'lbs',
                      ),
                    ),
                  ],
                ],
              )
            else if (isForRounds)
              TextField(
                controller: group.intervalMinCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Rounds',
                  border: OutlineInputBorder(), isDense: true, suffixText: 'rounds',
                ),
              )
            else if (isForTime)
              TextField(
                controller: group.intervalMinCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Time Cap',
                  border: OutlineInputBorder(), isDense: true, suffixText: 'min',
                ),
              )
            else
              TextField(
                controller: group.intervalMinCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Time cap',
                  border: OutlineInputBorder(), isDense: true, suffixText: 'min',
                ),
              ),
            const SizedBox(height: 14),
            // ── Single-exercise EMOM: one row per set/minute ──────────────────
            if (isSingleExEmom) ...[
              () {
                final ex = exList.first;
                final isTime = group.repOrTimeMode[ex] == 'time';
                group.syncSetControllers(ex, totalSets);
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Editable exercise name
                    TextField(
                      controller: group.nameCtrl[ex],
                      onChanged: (v) => ex.name = v,
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                      decoration: const InputDecoration(
                        isDense: true,
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(vertical: 6, horizontal: 8),
                        hintText: 'Exercise name',
                      ),
                    ),
                    const SizedBox(height: 10),
                    // Reps/Time mode selector (row-level setting)
                    Row(children: [
                      Text('Mode:', style: TextStyle(fontSize: 12, color: _w54)),
                      const SizedBox(width: 8),
                      DropdownButton<String>(
                        value: group.repOrTimeMode[ex] ?? 'reps',
                        isDense: true,
                        underline: const SizedBox(),
                        style: TextStyle(fontSize: 12, color: _w70),
                        dropdownColor: const Color(0xFF1E1E1E),
                        items: const [
                          DropdownMenuItem(value: 'reps', child: Text('Reps')),
                          DropdownMenuItem(value: 'time', child: Text('Time')),
                        ],
                        onChanged: (v) { if (v != null) setState(() => group.repOrTimeMode[ex] = v); },
                      ),
                    ]),
                    const SizedBox(height: 6),
                    // Column headers aligned to data rows
                    Row(children: [
                      const SizedBox(width: 52),
                      const SizedBox(width: 8),
                      SizedBox(width: 46, child: Text(isTime ? 'Time' : 'Reps',
                          style: TextStyle(fontSize: 11, color: _w38), textAlign: TextAlign.center)),
                      const SizedBox(width: 8),
                      if (isEmomStrength) ...[
                        SizedBox(width: 46, child: Text('%', style: TextStyle(fontSize: 11, color: _w38), textAlign: TextAlign.center)),
                        const SizedBox(width: 8),
                      ],
                      SizedBox(width: 70, child: Text(isTime ? 'RPE' : 'Weight',
                          style: TextStyle(fontSize: 11, color: _w38), textAlign: TextAlign.center)),
                      const SizedBox(width: 70),
                    ]),
                    const SizedBox(height: 4),
                    // One row per set
                    ...List.generate(totalSets, (i) => Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(children: [
                        SizedBox(
                          width: 52,
                          child: Text('Min ${i + 1}',
                              style: TextStyle(fontSize: 11, color: typeColor, fontWeight: FontWeight.w600)),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(width: 46, child: TextField(
                          controller: group.perSetRepsCtrl[ex]![i],
                          keyboardType: TextInputType.number,
                          textAlign: TextAlign.center,
                          onChanged: (v) {
                            final rList = group.perSetRepsCtrl[ex]!;
                            for (int j = i + 1; j < rList.length; j++) {
                              rList[j].value = TextEditingValue(text: v, selection: TextSelection.collapsed(offset: v.length));
                            }
                          },
                          decoration: InputDecoration(
                            isDense: true,
                            border: const OutlineInputBorder(),
                            contentPadding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                            suffixText: isTime ? 's' : null,
                          ),
                        )),
                        const SizedBox(width: 8),
                        if (isEmomStrength) ...[
                          SizedBox(width: 46, child: TextField(
                            controller: group.perSetPctCtrl[ex]![i],
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            textAlign: TextAlign.center,
                            onChanged: (v) {
                              final pct = double.tryParse(v);
                              final pList = group.perSetPctCtrl[ex]!;
                              final wList = group.perSetWeightCtrl[ex]!;
                              if (pct != null && workingMax > 0) {
                                final calc = (pct / 100 * workingMax).roundToDouble().toStringAsFixed(0);
                                wList[i].value = TextEditingValue(text: calc, selection: TextSelection.collapsed(offset: calc.length));
                              }
                              for (int j = i + 1; j < pList.length; j++) {
                                pList[j].value = TextEditingValue(text: v, selection: TextSelection.collapsed(offset: v.length));
                                if (pct != null && workingMax > 0 && j < wList.length) {
                                  final calc = (pct / 100 * workingMax).roundToDouble().toStringAsFixed(0);
                                  wList[j].value = TextEditingValue(text: calc, selection: TextSelection.collapsed(offset: calc.length));
                                }
                              }
                            },
                            decoration: const InputDecoration(
                              isDense: true,
                              border: OutlineInputBorder(),
                              contentPadding: EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                            ),
                          )),
                          const SizedBox(width: 8),
                        ],
                        SizedBox(width: 70, child: TextField(
                          controller: isTime
                              ? group.perSetRpeCtrl[ex]![i]
                              : group.perSetWeightCtrl[ex]![i],
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          textAlign: TextAlign.center,
                          onChanged: (v) {
                            final wList = isTime ? group.perSetRpeCtrl[ex]! : group.perSetWeightCtrl[ex]!;
                            for (int j = i + 1; j < wList.length; j++) {
                              wList[j].value = TextEditingValue(text: v, selection: TextSelection.collapsed(offset: v.length));
                            }
                          },
                          decoration: InputDecoration(
                            isDense: true,
                            border: const OutlineInputBorder(),
                            contentPadding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                            hintText: isTime ? 'RPE' : '–',
                          ),
                        )),
                        const SizedBox(width: 6),
                        _groupStatusBtnPair(group, ex, i),
                      ]),
                    )),
                  ],
                );
              }(),
            ] else ...[
            // ── Multi-exercise: one row per unique exercise ───────────────────
            // Column headers
            Row(children: [
              SizedBox(width: 28, child: Text('#', style: TextStyle(fontSize: 11, color: _w38))),
              const SizedBox(width: 8),
              Expanded(child: Text('Exercise', style: TextStyle(fontSize: 11, color: _w38))),
              const SizedBox(width: 8),
              if (isEmom)
                SizedBox(width: 110, child: Text('Reps / Time', style: TextStyle(fontSize: 11, color: _w38), textAlign: TextAlign.center))
              else
                SizedBox(width: 56, child: Text('Reps', style: TextStyle(fontSize: 11, color: _w38), textAlign: TextAlign.center)),
              const SizedBox(width: 8),
              if (isEmomStrength) ...[
                SizedBox(width: 46, child: Text('%', style: TextStyle(fontSize: 11, color: _w38), textAlign: TextAlign.center)),
                const SizedBox(width: 8),
              ],
              SizedBox(width: 70, child: Text('Wt / RPE', style: TextStyle(fontSize: 11, color: _w38), textAlign: TextAlign.center)),
              const SizedBox(width: 26),
            ]),
            const SizedBox(height: 4),
            ...exList.asMap().entries.map((e) {
              final idx = e.key;
              final ex = e.value;
              final isTime = isEmom && group.repOrTimeMode[ex] == 'time';
              return Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(children: [
                  SizedBox(
                    width: 28,
                    child: Text('${idx + 1}.',
                        style: TextStyle(fontSize: 13, color: typeColor, fontWeight: FontWeight.w600)),
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: TextField(
                    controller: group.nameCtrl[ex],
                    onChanged: (v) => ex.name = v,
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                    decoration: const InputDecoration(
                      isDense: true,
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(vertical: 6, horizontal: 8),
                      hintText: 'Exercise name',
                    ),
                  )),
                  const SizedBox(width: 8),
                  if (isEmom)
                    SizedBox(
                      width: 110,
                      child: Row(children: [
                        SizedBox(
                          width: 58,
                          child: DropdownButton<String>(
                            value: group.repOrTimeMode[ex] ?? 'reps',
                            isDense: true,
                            underline: const SizedBox(),
                            style: TextStyle(fontSize: 11, color: _w70),
                            dropdownColor: const Color(0xFF1E1E1E),
                            items: const [
                              DropdownMenuItem(value: 'reps', child: Text('Rep')),
                              DropdownMenuItem(value: 'time', child: Text('Time')),
                            ],
                            onChanged: (v) { if (v != null) setState(() => group.repOrTimeMode[ex] = v); },
                          ),
                        ),
                        const SizedBox(width: 2),
                        Expanded(child: TextField(
                          controller: group.repsCtrl[ex],
                          keyboardType: TextInputType.number,
                          textAlign: TextAlign.center,
                          decoration: InputDecoration(
                            isDense: true,
                            border: const OutlineInputBorder(),
                            contentPadding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
                            suffixText: isTime ? 's' : null,
                          ),
                        )),
                      ]),
                    )
                  else
                    SizedBox(width: 56, child: TextField(
                      controller: group.repsCtrl[ex],
                      keyboardType: TextInputType.number,
                      textAlign: TextAlign.center,
                      decoration: const InputDecoration(isDense: true, border: OutlineInputBorder(),
                          contentPadding: EdgeInsets.symmetric(vertical: 6, horizontal: 4)),
                    )),
                  const SizedBox(width: 8),
                  if (isEmomStrength) ...[
                    SizedBox(width: 46, child: TextField(
                      controller: group.pctCtrl[ex],
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      textAlign: TextAlign.center,
                      onChanged: (v) {
                        final pct = double.tryParse(v);
                        if (pct != null && workingMax > 0) {
                          group.weightCtrl[ex]!.text =
                              (pct / 100 * workingMax).roundToDouble().toStringAsFixed(0);
                        }
                      },
                      decoration: const InputDecoration(
                        isDense: true,
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                      ),
                    )),
                    const SizedBox(width: 8),
                  ],
                  SizedBox(width: 70, child: TextField(
                    controller: isTime ? group.rpeCtrl[ex] : group.weightCtrl[ex],
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    textAlign: TextAlign.center,
                    decoration: InputDecoration(
                      isDense: true,
                      border: const OutlineInputBorder(),
                      contentPadding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                      hintText: isTime ? 'RPE' : '–',
                    ),
                  )),
                  const SizedBox(width: 4),
                  // Delete exercise from group
                  GestureDetector(
                    onTap: exList.length <= 1 ? null : () {
                      setState(() {
                        group.nameCtrl[ex]?.dispose();
                        group.repsCtrl[ex]?.dispose();
                        group.weightCtrl[ex]?.dispose();
                        group.rpeCtrl[ex]?.dispose();
                        group.nameCtrl.remove(ex);
                        group.repsCtrl.remove(ex);
                        group.weightCtrl.remove(ex);
                        group.rpeCtrl.remove(ex);
                        group.repOrTimeMode.remove(ex);
                        exList.remove(ex);
                      });
                    },
                    child: Icon(Icons.close, size: 16,
                        color: exList.length > 1 ? _w38 : Colors.white12),
                  ),
                ]),
              );
            }),
            ],
            // Add Exercise to group
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: () async {
                  final blockKey = exList.isNotEmpty ? exList.first.block : '';
                  final names = await _showExercisePicker(
                    exclude: exList.map((e) => e.name).toSet(),
                  );
                  if (names.isEmpty || !mounted) return;
                  setState(() {
                    for (final name in names) {
                      group.addExercise(ProgramExercise(name: name, block: blockKey));
                    }
                  });
                },
                icon: Icon(Icons.add, size: 15, color: typeColor),
                label: Text('Add Exercise',
                    style: TextStyle(fontSize: 12, color: typeColor)),
              ),
            ),
            const SizedBox(height: 8),
            // Mark Done / Done for the whole group
            () {
              final groupDone = exList.isNotEmpty && exList.every((e) => e.completed);
              return groupDone
                  ? Row(children: [
                      Icon(Icons.check_circle, color: Colors.green.shade400, size: 18),
                      const SizedBox(width: 6),
                      Text('Completed', style: TextStyle(color: Colors.green.shade400, fontWeight: FontWeight.w600)),
                      const Spacer(),
                      TextButton(
                        onPressed: () => setState(() { for (final e in exList) { e.completed = false; } }),
                        style: TextButton.styleFrom(padding: EdgeInsets.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                        child: Text('Undo', style: TextStyle(fontSize: 12, color: _w38)),
                      ),
                    ])
                  : SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () => setState(() { for (final e in exList) { e.completed = true; } }),
                        icon: const Icon(Icons.check, size: 16),
                        label: const Text('Mark Done'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.green.shade400,
                          side: BorderSide(color: Colors.green.shade700),
                          padding: const EdgeInsets.symmetric(vertical: 8),
                        ),
                      ),
                    );
            }(),
          ],
        ),
      ),
    );
  }

  Widget _buildBlock(String title, String blockKey, List<_SectionItem> section) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          if (section.isEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text('No exercises yet.',
                  style: TextStyle(fontSize: 13,
                      color: Colors.white.withValues(alpha: 0.38))),
            )
          else
            ReorderableListView(
              shrinkWrap: true,
              buildDefaultDragHandles: false,
              physics: const NeverScrollableScrollPhysics(),
              onReorder: (oldIdx, newIdx) {
                setState(() {
                  if (newIdx > oldIdx) newIdx--;
                  section.insert(newIdx, section.removeAt(oldIdx));
                });
              },
              children: [
                for (int i = 0; i < section.length; i++)
                  section[i].isGroup
                      ? _buildGroupCard(section[i].group!, section, i)
                      : _buildExerciseCard(section[i].ex!, section, i),
              ],
            ),
          TextButton.icon(
            onPressed: () => _showAddMenu(blockKey, section),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add Exercise'),
            style: TextButton.styleFrom(
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 4),
            ),
          ),
          const Divider(height: 24),
        ],
      ),
    );
  }

  int _stepIndexFor(List<ProgramExercise> targetExs) {
    List<List<ProgramExercise>> group(List<ProgramExercise> block) {
      final result = <List<ProgramExercise>>[];
      final seen = <String>{};
      for (final ex in block) {
        if (ex.groupId == null) { result.add([ex]); }
        else if (!seen.contains(ex.groupId)) {
          seen.add(ex.groupId!);
          result.add(block.where((e) => e.groupId == ex.groupId).toList());
        }
      }
      return result;
    }
    final all = _outlineExercises;
    final warmUp = group(all.where((e) => e.block == 'warmUp').toList());
    final main = group(all.where((e) => e.block != 'warmUp' && e.block != 'coolDown').toList());
    final coolDown = group(all.where((e) => e.block == 'coolDown').toList());
    int idx = 0;
    if (warmUp.isNotEmpty) {
      if (warmUp.any((g) => g.any((e) => targetExs.contains(e)))) { return idx; }
      idx++;
    }
    for (final g in main) {
      if (g.any((e) => targetExs.contains(e))) { return idx; }
      idx++;
    }
    if (coolDown.isNotEmpty && coolDown.any((g) => g.any((e) => targetExs.contains(e)))) {
      return idx;
    }
    return 0;
  }

  void _openFlowAt(List<ProgramExercise> targetExs) {
    final exercises = _buildExerciseList();
    final stepIdx = _stepIndexFor(targetExs);
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => ProgramFlowScreen(
        exercises: exercises,
        dateLabel: _dateLabel,
        initialStepIndex: stepIdx,
        onCompleted: (String? notes) {
          final n = notes?.trim().isEmpty == true ? null : notes?.trim();
          _persistWorkout(exercises, completed: true, notes: n);
          if (mounted) setState(() => _outlineExercises = List.of(exercises));
        },
      ),
    ));
  }

  /// Groups flat exercises by groupId into [[solo], [group...], ...] order.
  List<List<ProgramExercise>> _getBlockItems(String blockKey) {
    final all = _outlineExercises;
    final filtered = all.where((e) =>
        e.block == blockKey ||
        (blockKey == 'main' && e.block != 'warmUp' && e.block != 'coolDown')).toList();
    final result = <List<ProgramExercise>>[];
    final seen = <String>{};
    for (final ex in filtered) {
      if (ex.groupId == null) {
        result.add([ex]);
      } else if (!seen.contains(ex.groupId)) {
        seen.add(ex.groupId!);
        result.add(filtered.where((e) => e.groupId == ex.groupId).toList());
      }
    }
    return result;
  }

  String _itemLabel(List<ProgramExercise> exs) {
    if (exs.isEmpty) return '';
    final first = exs.first;
    if (first.groupId == null) {
      if (first.sets.isEmpty) return first.name;
      final s = first.sets.first;
      final w = s.weight == null || s.weight == 0 ? ''
          : ' @ ${s.weight!.toInt()} ${s.unit}';
      return '${first.name} · ${first.sets.length}×${s.reps}$w';
    }
    final type = first.groupType ?? 'emom';
    final interval = first.groupIntervalMin ?? 1;
    final sec = first.groupIntervalSec ?? 0;
    final total = first.groupTotalSets ?? 6;
    final names = exs.map((e) => e.name).join(', ');
    final intervalLabel = sec > 0 ? '$interval:${sec.toString().padLeft(2, '0')}' : '$interval';
    final prefix = switch (type) {
      'emom' => interval == 1 && sec == 0 ? 'EMOM' : 'E${intervalLabel}MOM',
      'emomStrength' => interval == 1 && sec == 0 ? 'EMOM (Strength)' : 'E${intervalLabel}MOM (Strength)',
      'amrap' => 'AMRAP',
      'forRounds' => 'For Rounds',
      'forTime' => 'For Time',
      _ => 'Group',
    };
    final suffix = type == 'amrap' ? '$total min' : type == 'forRounds' ? '×$total rounds' : type == 'forTime' ? '${total}min' : '×$total';
    return '$prefix $suffix: $names';
  }


  Widget? _maxWeightRow(List<ProgramExercise> exs) {
    final parts = <String>[];
    for (final ex in exs) {
      final weights = ex.sets
          .where((s) => s.weight != null && s.weight! > 0)
          .map((s) => s.weight!);
      if (weights.isEmpty) continue;
      final maxW = weights.reduce((a, b) => a > b ? a : b);
      final unit = ex.sets.isNotEmpty ? ex.sets.first.unit : 'lbs';
      final wStr = maxW % 1 == 0 ? maxW.toInt().toString() : maxW.toStringAsFixed(1);
      parts.add(exs.length > 1 ? '${ex.name}: $wStr $unit' : 'Heaviest Weight: $wStr $unit');
    }
    if (parts.isEmpty) return null;
    return Padding(
      padding: const EdgeInsets.only(left: 26, bottom: 4),
      child: Text(parts.join('  ·  '),
          style: TextStyle(fontSize: 12, color: _w54)),
    );
  }

  Widget _buildOutlineSection(String title, String blockKey) {
    final items = _getBlockItems(blockKey);
    if (items.isEmpty) return const SizedBox.shrink();
    final isMain = blockKey == 'main';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(0, 16, 0, 4),
          child: Text(title,
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700,
                  color: _w54, letterSpacing: 0.8)),
        ),
        ...items.map((exs) {
          final done = exs.every((e) => e.completed);
          final label = _itemLabel(exs);
          final maxRow = (isMain && done) ? _maxWeightRow(exs) : null;
          return InkWell(
            onTap: () => _openFlowAt(exs),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(
                      done ? Icons.check_circle : Icons.radio_button_unchecked,
                      size: 16,
                      color: done ? Colors.green.shade400 : _w38,
                    ),
                    const SizedBox(width: 10),
                    Expanded(child: Text(label,
                        style: TextStyle(
                            fontSize: 14,
                            color: done ? _w70 : Colors.white))),
                    const Icon(Icons.chevron_right, size: 16, color: Colors.white24),
                  ]),
                  if (maxRow != null) ...[
                    const SizedBox(height: 2),
                    maxRow,
                  ],
                ],
              ),
            ),
          );
        }),
        const Divider(height: 8),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_dateLabel, style: const TextStyle(fontWeight: FontWeight.bold)),
        centerTitle: true,
        actions: _editMode
            ? [
                TextButton(
                  onPressed: _save,
                  child: const Text('Save', style: TextStyle(fontSize: 16)),
                ),
                const SizedBox(width: 8),
              ]
            : [
                TextButton.icon(
                  onPressed: () => setState(() => _editMode = true),
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  label: const Text('Edit', style: TextStyle(fontSize: 16)),
                ),
                const SizedBox(width: 8),
              ],
      ),
      floatingActionButton: _editMode
          ? null
          : FloatingActionButton(
              onPressed: _startWorkout,
              child: const Icon(Icons.arrow_forward),
            ),
      body: _editMode
          ? SingleChildScrollView(
              padding: const EdgeInsets.only(bottom: 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildBlock('Warm Up', 'warmUp', _warmUp),
                  _buildBlock('Main', 'main', _main),
                  _buildBlock('Cool Down', 'coolDown', _coolDown),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: TextField(
                      controller: _notesCtrl,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        labelText: 'Notes',
                        hintText: 'Add workout notes…',
                        border: OutlineInputBorder(),
                        alignLabelWithHint: true,
                      ),
                    ),
                  ),
                ],
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
              children: [
                _buildOutlineSection('Warm Up', 'warmUp'),
                _buildOutlineSection('Main', 'main'),
                _buildOutlineSection('Cool Down', 'coolDown'),
                if (widget.existingDay?.notes != null &&
                    widget.existingDay!.notes!.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.notes_outlined),
                      title: Text(widget.existingDay!.notes!),
                      subtitle: const Text('Notes'),
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                if (widget.existingDay?.completed == true)
                  Row(children: [
                    Icon(Icons.check_circle, color: Colors.green.shade400, size: 20),
                    const SizedBox(width: 8),
                    Text('Workout Completed',
                        style: TextStyle(color: Colors.green.shade400, fontWeight: FontWeight.w600)),
                  ])
                else
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      icon: const Icon(Icons.check),
                      label: const Text('Complete Workout'),
                      onPressed: () {
                        for (final ex in _outlineExercises) { ex.completed = true; }
                        _persistWorkout(_outlineExercises, completed: true);
                        setState(() {});
                      },
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.green,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}

// ─── Program Flow Screen (Guided Workout) ─────────────────────────────────────

enum _FlowStepKind { warmUp, mainItem, coolDown, done }

class _FlowStep {
  final _FlowStepKind kind;
  final List<List<ProgramExercise>> items;
  _FlowStep(this.kind, this.items);
}

class ProgramFlowScreen extends StatefulWidget {
  final List<ProgramExercise> exercises;
  final String dateLabel;
  final void Function(String? notes)? onCompleted;
  final int initialStepIndex;

  const ProgramFlowScreen({
    super.key,
    required this.exercises,
    required this.dateLabel,
    this.onCompleted,
    this.initialStepIndex = 0,
  });

  @override
  State<ProgramFlowScreen> createState() => _ProgramFlowScreenState();
}

class _ProgramFlowScreenState extends State<ProgramFlowScreen> {
  late final List<_FlowStep> _steps;
  late int _stepIndex;
  late final TextEditingController _notesCtrl;
  final Map<ProgramExercise, List<TextEditingController>> _repsCtrl = {};
  final Map<ProgramExercise, List<TextEditingController>> _weightCtrl = {};
  final Map<ProgramExercise, List<TextEditingController>> _rpeCtrl = {};
  final Map<ProgramExercise, List<TextEditingController>> _pctCtrl = {};
  final Map<ProgramExercise, TextEditingController> _workingMaxCtrl = {};
  final Map<ProgramExercise, TextEditingController> _groupIntervalMinCtrl = {};
  final Map<ProgramExercise, TextEditingController> _groupTotalSetsCtrl = {};
  final Map<ProgramExercise, List<SetStatus>> _statusMap = {};

  @override
  void dispose() {
    _notesCtrl.dispose();
    for (final list in _repsCtrl.values) { for (final c in list) { c.dispose(); } }
    for (final list in _weightCtrl.values) { for (final c in list) { c.dispose(); } }
    for (final list in _rpeCtrl.values) { for (final c in list) { c.dispose(); } }
    for (final list in _pctCtrl.values) { for (final c in list) { c.dispose(); } }
    for (final c in _workingMaxCtrl.values) { c.dispose(); }
    for (final c in _groupIntervalMinCtrl.values) { c.dispose(); }
    for (final c in _groupTotalSetsCtrl.values) { c.dispose(); }
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _steps = _buildSteps();
    _stepIndex = widget.initialStepIndex.clamp(0, _steps.length - 1);
    _notesCtrl = TextEditingController();
    _initControllers();
  }

  void _initControllers() {
    for (final step in _steps) {
      for (final exs in step.items) {
        // Initialize editable group config controllers (keyed by first exercise)
        if (exs.first.groupId != null && !_groupIntervalMinCtrl.containsKey(exs.first)) {
          _groupIntervalMinCtrl[exs.first] = TextEditingController(
              text: (exs.first.groupIntervalMin ?? 1).toString());
          _groupTotalSetsCtrl[exs.first] = TextEditingController(
              text: (exs.first.groupTotalSets ?? 6).toString());
        }
        for (final ex in exs) {
          if (_repsCtrl.containsKey(ex)) continue;
          // For single-exercise emom/emomStrength, pad to totalSets rows
          final isSingleExEmomGroup = exs.length == 1 &&
              ex.groupId != null &&
              (ex.groupType == 'emom' || ex.groupType == 'emomStrength');
          final targetCount = isSingleExEmomGroup && (ex.groupTotalSets ?? 0) > 0
              ? ex.groupTotalSets!
              : (ex.sets.isNotEmpty ? ex.sets.length : 0);
          final template = ex.sets.isNotEmpty ? ex.sets.first : ProgramSet(reps: 10);
          final padded = List.generate(targetCount,
              (i) => i < ex.sets.length ? ex.sets[i] : ProgramSet(reps: template.reps));
          _repsCtrl[ex] = padded.map((s) => TextEditingController(
              text: s.reps == 0 ? '' : '${s.reps}')).toList();
          _weightCtrl[ex] = padded.map((s) => TextEditingController(
              text: s.weight == null || s.weight == 0 ? ''
                  : (s.weight! % 1 == 0
                      ? s.weight!.toInt().toString()
                      : s.weight!.toStringAsFixed(1)))).toList();
          _rpeCtrl[ex] = padded.map((s) => TextEditingController(
              text: s.rpe == null ? '' : s.rpe!.toStringAsFixed(1))).toList();
          _pctCtrl[ex] = padded.map((s) => TextEditingController(
              text: s.pct == null ? '' : s.pct!.toStringAsFixed(0))).toList();
          _statusMap[ex] = padded.map((s) => s.status).toList();
          if (ex.groupType == 'emomStrength') {
            _workingMaxCtrl[ex] = TextEditingController(
                text: ex.groupWorkingMax != null && ex.groupWorkingMax! > 0
                    ? ex.groupWorkingMax!.toStringAsFixed(0)
                    : '');
          }
        }
      }
    }
  }

  void _saveStepData(_FlowStep step) {
    for (final exs in step.items) {
      // Save editable group config values to all exercises in the group
      if (exs.first.groupId != null) {
        final newMin = int.tryParse(_groupIntervalMinCtrl[exs.first]?.text ?? '');
        final newTotal = int.tryParse(_groupTotalSetsCtrl[exs.first]?.text ?? '');
        for (final ex in exs) {
          if (newMin != null) ex.groupIntervalMin = newMin;
          if (newTotal != null) ex.groupTotalSets = newTotal;
        }
      }
      for (final ex in exs) {
        final rList = _repsCtrl[ex];
        final wList = _weightCtrl[ex];
        if (rList == null || rList.isEmpty) continue;
        final unit = ex.sets.isNotEmpty ? ex.sets.first.unit : 'lbs';
        final eList = _rpeCtrl[ex];
        final pList = _pctCtrl[ex];
        final sList = _statusMap[ex];
        final wmCtrl = _workingMaxCtrl[ex];
        if (wmCtrl != null) ex.groupWorkingMax = double.tryParse(wmCtrl.text);
        ex.sets = List.generate(rList.length, (i) {
          final old = i < ex.sets.length ? ex.sets[i] : null;
          return ProgramSet(
            reps: int.tryParse(rList[i].text) ?? 0,
            weight: double.tryParse(wList![i].text),
            unit: old?.unit ?? unit,
            rpe: double.tryParse(eList?[i].text ?? ''),
            pct: double.tryParse(pList?[i].text ?? ''),
            status: sList != null && i < sList.length ? sList[i] : (old?.status ?? SetStatus.none),
          );
        });
      }
    }
  }

  void _saveAllSteps() {
    for (final step in _steps.where((s) => s.kind != _FlowStepKind.done)) {
      _saveStepData(step);
    }
  }

  List<List<ProgramExercise>> _groupItems(String blockKey) {
    final filtered = widget.exercises.where((e) =>
        blockKey == 'main'
            ? (e.block != 'warmUp' && e.block != 'coolDown')
            : e.block == blockKey).toList();
    final result = <List<ProgramExercise>>[];
    final seen = <String>{};
    for (final ex in filtered) {
      if (ex.groupId == null) {
        result.add([ex]);
      } else if (!seen.contains(ex.groupId)) {
        seen.add(ex.groupId!);
        result.add(filtered.where((e) => e.groupId == ex.groupId).toList());
      }
    }
    return result;
  }

  List<_FlowStep> _buildSteps() {
    final steps = <_FlowStep>[];
    final warmUp = _groupItems('warmUp');
    final main = _groupItems('main');
    final coolDown = _groupItems('coolDown');
    if (warmUp.isNotEmpty) steps.add(_FlowStep(_FlowStepKind.warmUp, warmUp));
    for (final item in main) { steps.add(_FlowStep(_FlowStepKind.mainItem, [item])); }
    if (coolDown.isNotEmpty) steps.add(_FlowStep(_FlowStepKind.coolDown, coolDown));
    steps.add(_FlowStep(_FlowStepKind.done, []));
    return steps;
  }

Widget _buildSetsTable(BuildContext context, ProgramExercise ex, {bool showStatus = true}) {
    final rList = _repsCtrl[ex];
    final wList = _weightCtrl[ex];
    final eList = _rpeCtrl[ex];
    final unit = ex.sets.isNotEmpty ? ex.sets.first.unit : 'lbs';
    final readOnly = ex.completed;
    if (rList == null || rList.isEmpty) {
      if (!readOnly) {
        return TextButton.icon(
          onPressed: () => setState(() {
            _repsCtrl[ex]!.add(TextEditingController());
            _weightCtrl[ex]!.add(TextEditingController());
            _rpeCtrl[ex]!.add(TextEditingController());
          }),
          icon: const Icon(Icons.add, size: 16),
          label: const Text('Add Set'),
        );
      }
      return Text('No sets', style: TextStyle(color: _w38, fontSize: 13));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          SizedBox(width: 24, child: Text('Set', style: TextStyle(fontSize: 11, color: _w38))),
          const SizedBox(width: 8),
          SizedBox(width: 56, child: Text('Reps', style: TextStyle(fontSize: 11, color: _w38))),
          const SizedBox(width: 8),
          Expanded(child: Text('Weight ($unit)', style: TextStyle(fontSize: 11, color: _w38))),
          const SizedBox(width: 8),
          SizedBox(width: 48, child: Text('RPE', style: TextStyle(fontSize: 11, color: _w38), textAlign: TextAlign.center)),
          if (!readOnly) const SizedBox(width: 32),
          const SizedBox(width: 70),
        ]),
        const SizedBox(height: 6),
        ...List.generate(rList.length, (i) => Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(children: [
            SizedBox(width: 24, child: Text('${i + 1}',
                style: TextStyle(fontSize: 13,
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.bold))),
            const SizedBox(width: 8),
            if (readOnly) ...[
              SizedBox(width: 56, child: Text(rList[i].text.isEmpty ? '–' : rList[i].text,
                  style: const TextStyle(fontSize: 14))),
              const SizedBox(width: 8),
              Expanded(child: Text(wList![i].text.isEmpty ? '–' : wList[i].text,
                  style: const TextStyle(fontSize: 14))),
              const SizedBox(width: 8),
              SizedBox(width: 48, child: Text(eList![i].text.isEmpty ? '–' : eList[i].text,
                  textAlign: TextAlign.center, style: const TextStyle(fontSize: 14))),
            ] else ...[
              SizedBox(width: 56, child: TextField(
                controller: rList[i],
                keyboardType: TextInputType.number,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13),
                onChanged: (v) {
                  for (int j = i + 1; j < rList.length; j++) {
                    rList[j].value = TextEditingValue(text: v, selection: TextSelection.collapsed(offset: v.length));
                  }
                },
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(vertical: 7, horizontal: 4),
                ),
              )),
              const SizedBox(width: 8),
              Expanded(child: TextField(
                controller: wList![i],
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13),
                onChanged: (v) {
                  for (int j = i + 1; j < wList.length; j++) {
                    wList[j].value = TextEditingValue(text: v, selection: TextSelection.collapsed(offset: v.length));
                  }
                },
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(vertical: 7, horizontal: 4),
                ),
              )),
              const SizedBox(width: 8),
              SizedBox(width: 48, child: TextField(
                controller: eList![i],
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13),
                onChanged: (v) {
                  for (int j = i + 1; j < eList.length; j++) {
                    eList[j].value = TextEditingValue(text: v, selection: TextSelection.collapsed(offset: v.length));
                  }
                },
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(vertical: 7, horizontal: 4),
                  hintText: '–',
                ),
              )),
              const SizedBox(width: 8),
              SizedBox(width: 24, child: IconButton(
                padding: EdgeInsets.zero,
                icon: Icon(Icons.close, size: 16, color: _w38),
                onPressed: () => setState(() {
                  rList.removeAt(i);
                  wList.removeAt(i);
                  eList.removeAt(i);
                  _statusMap[ex]?.removeAt(i);
                  _pctCtrl[ex]?.removeAt(i);
                }),
              )),
            ],
            if (showStatus) _statusButtons(ex, i),
          ]),
        )),
        if (!readOnly)
          TextButton.icon(
            onPressed: () => setState(() {
              rList.add(TextEditingController());
              wList!.add(TextEditingController());
              eList!.add(TextEditingController());
            }),
            icon: const Icon(Icons.add, size: 16),
            label: const Text('Add Set'),
            style: TextButton.styleFrom(
              foregroundColor: _w54,
              padding: const EdgeInsets.symmetric(vertical: 4),
              visualDensity: VisualDensity.compact,
            ),
          ),
      ],
    );
  }

  Widget _statusButtons(ProgramExercise ex, int i) {
    final sList = _statusMap[ex];
    if (sList == null || i >= sList.length) return const SizedBox.shrink();
    final status = sList[i];
    final locked = ex.completed == true;

    // When locked (workout marked done), show only the selected icon as static
    if (locked) {
      if (status == SetStatus.missed) {
        return Row(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(width: 6),
          Container(
            width: 28, height: 28,
            decoration: BoxDecoration(color: Colors.red, borderRadius: BorderRadius.circular(6)),
            child: const Icon(Icons.close, size: 14, color: Colors.white),
          ),
          const SizedBox(width: 32),
        ]);
      }
      if (status == SetStatus.succeeded) {
        return Row(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(width: 38),
          Container(
            width: 28, height: 28,
            decoration: BoxDecoration(color: Colors.green, borderRadius: BorderRadius.circular(6)),
            child: const Icon(Icons.check, size: 14, color: Colors.white),
          ),
        ]);
      }
      // no status selected and locked — show empty space
      return const SizedBox(width: 66);
    }

    // Not locked — fully toggleable
    return Row(mainAxisSize: MainAxisSize.min, children: [
      const SizedBox(width: 6),
      GestureDetector(
        onTap: () => setState(() {
          sList[i] = status == SetStatus.missed ? SetStatus.none : SetStatus.missed;
        }),
        child: Container(
          width: 28, height: 28,
          decoration: BoxDecoration(
            color: status == SetStatus.missed ? Colors.red : Colors.white10,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Icon(Icons.close, size: 14,
              color: status == SetStatus.missed ? Colors.white : _w38),
        ),
      ),
      const SizedBox(width: 4),
      GestureDetector(
        onTap: () => setState(() {
          sList[i] = status == SetStatus.succeeded ? SetStatus.none : SetStatus.succeeded;
        }),
        child: Container(
          width: 28, height: 28,
          decoration: BoxDecoration(
            color: status == SetStatus.succeeded ? Colors.green : Colors.white10,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Icon(Icons.check, size: 14,
              color: status == SetStatus.succeeded ? Colors.white : _w38),
        ),
      ),
    ]);
  }

  Widget _buildInfoField(String label, String value, String? suffix) {
    return InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        isDense: true,
        suffixText: suffix,
        contentPadding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
      ),
      child: Text(value, style: const TextStyle(fontSize: 14)),
    );
  }

  Widget _buildExerciseBlock(BuildContext context, List<ProgramExercise> exs, {bool showStatus = true}) {
    final isGroup = exs.first.groupId != null;

    if (!isGroup) {
      final ex = exs.first;
      return Card(
        margin: const EdgeInsets.symmetric(vertical: 8),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(ex.name, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              _buildSetsTable(context, ex, showStatus: showStatus),
            ],
          ),
        ),
      );
    }

    final type = exs.first.groupType ?? 'emom';
    final isEmom = type == 'emom' || type == 'emomStrength';
    final intervalMin = exs.first.groupIntervalMin ?? 1;
    final totalSets = exs.first.groupTotalSets ?? 6;
    final isSingleExEmom = isEmom && exs.length == 1;
    final typeColor = type == 'emomStrength'
        ? Colors.deepPurple
        : type == 'emom' ? Colors.orange
        : type == 'forRounds' ? Colors.indigo
        : type == 'forTime' ? Colors.cyan.shade700
        : Colors.teal;
    final badgeText = type == 'emomStrength'
        ? 'EMOM (Strength)'
        : type == 'emom' ? 'EMOM'
        : type == 'forRounds' ? 'For Rounds'
        : type == 'forTime' ? 'For Time'
        : 'AMRAP';

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: typeColor.withValues(alpha: 0.6), width: 1.5),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Badge
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: typeColor.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(badgeText,
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: typeColor)),
            ),
            const SizedBox(height: 12),
            // Config info (editable when not completed)
            Builder(builder: (ctx) {
              final groupDone = exs.every((e) => e.completed);
              final iMinCtrl = _groupIntervalMinCtrl[exs.first];
              final tSetsCtrl = _groupTotalSetsCtrl[exs.first];
              if (groupDone || iMinCtrl == null || tSetsCtrl == null) {
                if (isEmom) {
                  return Row(children: [
                    Expanded(child: _buildInfoField('Min per interval', '$intervalMin', 'min')),
                    const SizedBox(width: 12),
                    Expanded(child: _buildInfoField('Total sets', '$totalSets', null)),
                  ]);
                }
                if (type == 'forRounds') {
                  return _buildInfoField('Rounds', '$totalSets', 'rounds');
                }
                if (type == 'forTime') {
                  return _buildInfoField('Time Cap', '$totalSets', 'min');
                }
                return _buildInfoField('Time cap', '$totalSets', 'min');
              }
              if (isEmom) {
                return Row(children: [
                  Expanded(child: TextField(
                    controller: iMinCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Min per interval',
                      border: OutlineInputBorder(),
                      isDense: true,
                      suffixText: 'min',
                    ),
                  )),
                  const SizedBox(width: 12),
                  Expanded(child: TextField(
                    controller: tSetsCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Total sets',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  )),
                ]);
              }
              if (type == 'forRounds') {
                return TextField(
                  controller: tSetsCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Rounds',
                    border: OutlineInputBorder(),
                    isDense: true,
                    suffixText: 'rounds',
                  ),
                );
              }
              if (type == 'forTime') {
                return TextField(
                  controller: tSetsCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Time Cap',
                    border: OutlineInputBorder(),
                    isDense: true,
                    suffixText: 'min',
                  ),
                );
              }
              return TextField(
                controller: tSetsCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Time cap',
                  border: OutlineInputBorder(),
                  isDense: true,
                  suffixText: 'min',
                ),
              );
            }),
            const SizedBox(height: 14),
            if (isSingleExEmom) ...[
              // Single-exercise EMOM / EMOM (Strength): per-minute rows
              () {
                final ex = exs.first;
                final rList = _repsCtrl[ex] ?? [];
                final wList = _weightCtrl[ex] ?? [];
                final pList = _pctCtrl[ex] ?? [];
                final readOnly = ex.completed;
                final isStrength = type == 'emomStrength';
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (isStrength) ...[
                      TextField(
                        controller: _workingMaxCtrl[ex],
                        readOnly: readOnly,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: const InputDecoration(
                          labelText: 'Working Max',
                          border: OutlineInputBorder(),
                          isDense: true,
                          suffixText: 'lbs',
                        ),
                        onChanged: (v) {
                          final wm = double.tryParse(v) ?? 0;
                          if (wm <= 0) return;
                          setState(() {
                            for (int i = 0; i < pList.length; i++) {
                              final pct = double.tryParse(pList[i].text);
                              if (pct != null && wList.length > i) {
                                wList[i].text = (pct / 100 * wm).roundToDouble().toStringAsFixed(0);
                              }
                            }
                          });
                        },
                      ),
                      const SizedBox(height: 10),
                    ],
                    Text(ex.name, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                    const SizedBox(height: 8),
                    Row(children: [
                      const SizedBox(width: 52),
                      const SizedBox(width: 8),
                      SizedBox(width: 46, child: Text('Reps',
                          style: TextStyle(fontSize: 11, color: _w38),
                          textAlign: TextAlign.center)),
                      if (isStrength) ...[
                        const SizedBox(width: 8),
                        SizedBox(width: 46, child: Text('%',
                            style: TextStyle(fontSize: 11, color: _w38),
                            textAlign: TextAlign.center)),
                      ],
                      const SizedBox(width: 8),
                      SizedBox(width: 70, child: Text('Weight',
                          style: TextStyle(fontSize: 11, color: _w38),
                          textAlign: TextAlign.center)),
                      if (showStatus) const SizedBox(width: 66),
                    ]),
                    const SizedBox(height: 4),
                    ...List.generate(rList.length, (i) => Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(children: [
                        SizedBox(width: 52, child: Text('Min ${i + 1}',
                            style: TextStyle(fontSize: 11, color: typeColor, fontWeight: FontWeight.w600))),
                        const SizedBox(width: 8),
                        if (readOnly) ...[
                          SizedBox(width: 46, child: Text(
                              rList[i].text.isEmpty ? '–' : rList[i].text,
                              textAlign: TextAlign.center,
                              style: const TextStyle(fontSize: 14))),
                          if (isStrength) ...[
                            const SizedBox(width: 8),
                            SizedBox(width: 46, child: Text(
                                pList.length > i && pList[i].text.isNotEmpty ? '${pList[i].text}%' : '–',
                                textAlign: TextAlign.center,
                                style: const TextStyle(fontSize: 14))),
                          ],
                          const SizedBox(width: 8),
                          SizedBox(width: 70, child: Text(
                              wList[i].text.isEmpty ? '–' : wList[i].text,
                              textAlign: TextAlign.center,
                              style: const TextStyle(fontSize: 14))),
                        ] else ...[
                          SizedBox(width: 46, child: TextField(
                            controller: rList[i],
                            keyboardType: TextInputType.number,
                            textAlign: TextAlign.center,
                            onChanged: (v) {
                              for (int j = i + 1; j < rList.length; j++) {
                                rList[j].value = TextEditingValue(text: v, selection: TextSelection.collapsed(offset: v.length));
                              }
                            },
                            decoration: const InputDecoration(
                              isDense: true, border: OutlineInputBorder(),
                              contentPadding: EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                            ),
                          )),
                          if (isStrength && pList.length > i) ...[
                            const SizedBox(width: 8),
                            SizedBox(width: 46, child: TextField(
                              controller: pList[i],
                              keyboardType: const TextInputType.numberWithOptions(decimal: true),
                              textAlign: TextAlign.center,
                              onChanged: (v) {
                                final pct = double.tryParse(v);
                                final wm = double.tryParse(_workingMaxCtrl[ex]?.text ?? '') ?? 0;
                                setState(() {
                                  if (pct != null && wm > 0 && wList.length > i) {
                                    wList[i].text = (pct / 100 * wm).roundToDouble().toStringAsFixed(0);
                                  }
                                  for (int j = i + 1; j < pList.length; j++) {
                                    pList[j].value = TextEditingValue(text: v, selection: TextSelection.collapsed(offset: v.length));
                                    if (pct != null && wm > 0 && wList.length > j) {
                                      final wStr = (pct / 100 * wm).roundToDouble().toStringAsFixed(0);
                                      wList[j].value = TextEditingValue(text: wStr, selection: TextSelection.collapsed(offset: wStr.length));
                                    }
                                  }
                                });
                              },
                              decoration: const InputDecoration(
                                isDense: true, border: OutlineInputBorder(),
                                contentPadding: EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                              ),
                            )),
                          ],
                          const SizedBox(width: 8),
                          SizedBox(width: 70, child: TextField(
                            controller: wList[i],
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            textAlign: TextAlign.center,
                            onChanged: (v) {
                              for (int j = i + 1; j < wList.length; j++) {
                                wList[j].value = TextEditingValue(text: v, selection: TextSelection.collapsed(offset: v.length));
                              }
                            },
                            decoration: const InputDecoration(
                              isDense: true, border: OutlineInputBorder(),
                              contentPadding: EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                              hintText: '–',
                            ),
                          )),
                        ],
                        if (showStatus) _statusButtons(ex, i),
                      ]),
                    )),
                  ],
                );
              }(),
            ] else ...[
              // Multi-exercise EMOM/AMRAP: one row per exercise
              Row(children: [
                const SizedBox(width: 28),
                const SizedBox(width: 8),
                Expanded(child: Text('Exercise',
                    style: TextStyle(fontSize: 11, color: _w38))),
                const SizedBox(width: 8),
                SizedBox(width: 56, child: Text('Reps',
                    style: TextStyle(fontSize: 11, color: _w38),
                    textAlign: TextAlign.center)),
                const SizedBox(width: 8),
                SizedBox(width: 70, child: Text('Wt / RPE',
                    style: TextStyle(fontSize: 11, color: _w38),
                    textAlign: TextAlign.center)),
                if (showStatus) const SizedBox(width: 66),
              ]),
              const SizedBox(height: 4),
              ...exs.asMap().entries.map((e) {
                final idx = e.key;
                final ex = e.value;
                final rList = _repsCtrl[ex] ?? [];
                final wList = _weightCtrl[ex] ?? [];
                final readOnly = ex.completed;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(children: [
                    SizedBox(width: 28, child: Text('${idx + 1}.',
                        style: TextStyle(fontSize: 13, color: typeColor, fontWeight: FontWeight.w600))),
                    const SizedBox(width: 8),
                    Expanded(child: Text(ex.name,
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500))),
                    const SizedBox(width: 8),
                    if (readOnly) ...[
                      SizedBox(width: 56, child: Text(
                          rList.isNotEmpty ? (rList[0].text.isEmpty ? '–' : rList[0].text) : '–',
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 14))),
                      const SizedBox(width: 8),
                      SizedBox(width: 70, child: Text(
                          wList.isNotEmpty ? (wList[0].text.isEmpty ? '–' : wList[0].text) : '–',
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 14))),
                    ] else ...[
                      SizedBox(width: 56, child: TextField(
                        controller: rList.isNotEmpty ? rList[0] : null,
                        keyboardType: TextInputType.number,
                        textAlign: TextAlign.center,
                        decoration: const InputDecoration(
                          isDense: true, border: OutlineInputBorder(),
                          contentPadding: EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                        ),
                      )),
                      const SizedBox(width: 8),
                      SizedBox(width: 70, child: TextField(
                        controller: wList.isNotEmpty ? wList[0] : null,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        textAlign: TextAlign.center,
                        decoration: const InputDecoration(
                          isDense: true, border: OutlineInputBorder(),
                          contentPadding: EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                          hintText: '–',
                        ),
                      )),
                    ],
                    if (showStatus) _statusButtons(ex, 0),
                  ]),
                );
              }),
            ],
          ],
        ),
      ),
    );
  }

  bool _stepHasEmptyBoxes(_FlowStep step) {
    for (final exs in step.items) {
      for (final ex in exs) {
        for (final s in ex.sets) {
          if (s.reps == 0 || s.weight == null || s.weight == 0) return true;
        }
      }
    }
    return false;
  }

  Widget _buildStepBody(BuildContext context, _FlowStep step) {
    Widget exerciseContent;
    String? sectionLabel;
    switch (step.kind) {
      case _FlowStepKind.warmUp:
        sectionLabel = 'WARM UP';
        exerciseContent = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: step.items.map((exs) => _buildExerciseBlock(context, exs, showStatus: false)).toList(),
        );
      case _FlowStepKind.mainItem:
        sectionLabel = 'MAIN';
        exerciseContent = _buildExerciseBlock(context, step.items.first);
      case _FlowStepKind.coolDown:
        sectionLabel = 'COOL DOWN';
        exerciseContent = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: step.items.map((exs) => _buildExerciseBlock(context, exs)).toList(),
        );
      case _FlowStepKind.done:
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.fitness_center, color: _w54, size: 64),
                const SizedBox(height: 24),
                const Text('Workout Finished!',
                    style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Text(widget.dateLabel,
                    style: TextStyle(fontSize: 16, color: _w54)),
                const SizedBox(height: 40),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () {
                      _saveAllSteps();
                      // Auto-complete steps with no empty boxes
                      for (final s in _steps.where((s) => s.kind != _FlowStepKind.done)) {
                        if (!_stepHasEmptyBoxes(s)) {
                          for (final exs in s.items) {
                            for (final ex in exs) {
                              ex.completed = true;
                            }
                          }
                        }
                      }
                      widget.onCompleted?.call(_notesCtrl.text.trim().isEmpty
                          ? null
                          : _notesCtrl.text.trim());
                      Navigator.pop(context);
                    },
                    icon: const Icon(Icons.check_circle_outline),
                    label: const Text('Complete Workout',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.green.shade700,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: const Text('Return Without Completing',
                        style: TextStyle(fontSize: 15)),
                  ),
                ),
              ],
            ),
          ),
        );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(sectionLabel, style: TextStyle(
                fontSize: 12, fontWeight: FontWeight.w700,
                color: _w54, letterSpacing: 1.0)),
          ),
          exerciseContent,
          const SizedBox(height: 16),
          TextField(
            controller: _notesCtrl,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Notes',
              hintText: 'Add notes for this section…',
              border: OutlineInputBorder(),
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 12),
          Builder(builder: (ctx) {
            final allDone = step.items.expand((exs) => exs).every((e) => e.completed);
            if (allDone) {
              return Row(children: [
                Icon(Icons.check_circle, color: Colors.green.shade400, size: 18),
                const SizedBox(width: 8),
                Text('Done',
                    style: TextStyle(color: Colors.green.shade400, fontSize: 14)),
                const Spacer(),
                OutlinedButton.icon(
                  onPressed: () => setState(() {
                    for (final exs in step.items) {
                      for (final ex in exs) { ex.completed = false; }
                    }
                  }),
                  icon: const Icon(Icons.edit_outlined, size: 16),
                  label: const Text('Edit'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _w70,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ]);
            }
            return SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () {
                  _saveStepData(step);
                  setState(() {
                    for (final exs in step.items) {
                      for (final ex in exs) { ex.completed = true; }
                    }
                  });
                },
                icon: const Icon(Icons.check, size: 16),
                label: const Text('Mark as Done'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.green.shade400,
                  side: BorderSide(color: Colors.green.shade400),
                ),
              ),
            );
          }),
        ],
      ),
    );
  }


  String get _appBarTitle {
    if (_stepIndex >= _steps.length) return '';
    final step = _steps[_stepIndex];
    switch (step.kind) {
      case _FlowStepKind.warmUp: return 'Warm Up';
      case _FlowStepKind.mainItem:
        final exs = step.items.first;
        final ex = exs.first;
        final name = exs.length == 1 ? ex.name : null;
        if (ex.groupType == 'emom' || ex.groupType == 'emomStrength') {
          final interval = ex.groupIntervalMin ?? 2;
          final sec = ex.groupIntervalSec ?? 0;
          final totalSets = ex.groupTotalSets ?? ex.sets.length;
          final intervalLabel = sec > 0 ? '$interval:${sec.toString().padLeft(2, '0')}' : '$interval';
          final label = 'E${intervalLabel}MOM x $totalSets sets';
          return name != null ? '$name: $label' : label;
        }
        if (ex.groupType == 'amrap') {
          final cap = ex.groupTotalSets ?? 0;
          final label = 'AMRAP ${cap}min';
          return name != null ? '$name: $label' : label;
        }
        if (ex.groupType == 'forRounds') {
          final rounds = ex.groupTotalSets ?? 3;
          final label = 'For Rounds ×$rounds';
          return name != null ? '$name: $label' : label;
        }
        if (ex.groupType == 'forTime') {
          final cap = ex.groupTotalSets ?? 20;
          final label = 'For Time ${cap}min';
          return name != null ? '$name: $label' : label;
        }
        // Standalone
        final sets = ex.sets.length;
        final reps = ex.sets.isNotEmpty ? ex.sets.first.reps : 0;
        return '${ex.name}: ${sets}x$reps';
      case _FlowStepKind.coolDown: return 'Cool Down';
      case _FlowStepKind.done: return 'Complete';
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_steps.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Start Workout')),
        body: const Center(child: Text('No exercises found.')),
      );
    }
    final step = _steps[_stepIndex];
    final isDone = step.kind == _FlowStepKind.done;
    return Scaffold(
      appBar: AppBar(
        title: Text(_appBarTitle),
        centerTitle: true,
        actions: null,
      ),
      body: Column(
        children: [
          Expanded(child: _buildStepBody(context, step)),
          if (!isDone)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // Back button — outlined circle
                  SizedBox(
                    width: 56,
                    height: 56,
                    child: OutlinedButton(
                      onPressed: () {
                        _saveStepData(_steps[_stepIndex]);
                        if (_stepIndex == 0) {
                          Navigator.pop(context);
                        } else {
                          setState(() => _stepIndex--);
                        }
                      },
                      style: OutlinedButton.styleFrom(
                        shape: const CircleBorder(),
                        padding: EdgeInsets.zero,
                      ),
                      child: const Icon(Icons.arrow_back),
                    ),
                  ),
                  // Next / Finish button — filled circle
                  SizedBox(
                    width: 56,
                    height: 56,
                    child: FilledButton(
                      onPressed: () {
                        _saveStepData(_steps[_stepIndex]);
                        setState(() => _stepIndex++);
                      },
                      style: FilledButton.styleFrom(
                        shape: const CircleBorder(),
                        padding: EdgeInsets.zero,
                      ),
                      child: Icon(
                        _stepIndex == _steps.length - 2
                            ? Icons.check
                            : Icons.arrow_forward,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
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
            size: 18, color: active ? Colors.white : _w38),
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
              Text('Unit:', style: TextStyle(color: _w70)),
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
          Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(children: [
              SizedBox(width: 28,
                  child: Text('Set', style: TextStyle(fontSize: 11, color: _w38))),
              SizedBox(width: 8),
              SizedBox(width: 60,
                  child: Text('Reps', style: TextStyle(fontSize: 11, color: _w38))),
              SizedBox(width: 8),
              Expanded(
                  child: Text('Weight', style: TextStyle(fontSize: 11, color: _w38))),
              SizedBox(width: 8),
              SizedBox(width: 52,
                  child: Text('RPE', style: TextStyle(fontSize: 11, color: _w38),
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
                Text('Enter your current password to continue.',
                    style: TextStyle(fontSize: 13, color: _w70)),
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
          Text('Account Details',
              style: TextStyle(fontSize: 13, color: _w54, fontWeight: FontWeight.w600)),
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
          Text('Appearance',
              style: TextStyle(fontSize: 13, color: _w54, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          ValueListenableBuilder<ThemeMode>(
            valueListenable: themeNotifier,
            builder: (context, mode, _) => SwitchListTile(
              title: const Text('Light Mode'),
              secondary: Icon(mode == ThemeMode.light ? Icons.light_mode : Icons.dark_mode),
              value: mode == ThemeMode.light,
              onChanged: (v) async {
                themeNotifier.value = v ? ThemeMode.light : ThemeMode.dark;
                final prefs = await SharedPreferences.getInstance();
                await prefs.setString('themeMode', v ? 'light' : 'dark');
              },
              contentPadding: EdgeInsets.zero,
            ),
          ),
          const SizedBox(height: 24),
          const Divider(),
          const SizedBox(height: 24),
          Text('Security',
              style: TextStyle(fontSize: 13, color: _w54, fontWeight: FontWeight.w600)),
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
          Icon(icon, size: 12, color: _w38),
          const SizedBox(width: 4),
          Text('$label: ',
              style: TextStyle(fontSize: 11, color: _w38)),
          Expanded(
            child: Text(value,
                style: TextStyle(fontSize: 11, color: _w70),
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
          if (widget.isOwnProfile) ...[
            IconButton(
              icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
              onPressed: _deleteWorkout,
            ),
          ],
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
                if (widget.workout.notes != null && widget.workout.notes!.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.notes_outlined),
                      title: Text(widget.workout.notes!),
                      subtitle: const Text('Notes'),
                    ),
                  ),
                ],
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
          if (widget.isOwnProfile && !widget.workout.completed)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  icon: const Icon(Icons.check),
                  label: const Text('Complete Workout'),
                  onPressed: () {
                    setState(() => widget.workout.completed = true);
                    widget.onChanged();
                  },
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.green,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
            )
          else if (widget.isOwnProfile && widget.workout.completed)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Center(
                child: GestureDetector(
                  onTap: () {
                    setState(() => widget.workout.completed = false);
                    widget.onChanged();
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => WorkoutScreen(
                          profile: widget.profile,
                          editingWorkout: widget.workout,
                          onSaved: () {
                            setState(() {});
                            widget.onChanged();
                          },
                        ),
                      ),
                    );
                  },
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.check_circle, color: Colors.green.shade400, size: 20),
                    const SizedBox(width: 8),
                    Text('Workout Completed',
                        style: TextStyle(color: Colors.green.shade400, fontWeight: FontWeight.w600)),
                    const SizedBox(width: 8),
                    Text('(tap to undo)',
                        style: TextStyle(color: _w38, fontSize: 12)),
                  ]),
                ),
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
              if (widget.isOwnProfile && !widget.workout.completed)
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
                Text('No sets logged', style: TextStyle(color: _w54))
              else ...[
                Row(children: [
                  SizedBox(width: 36, child: Text('Set', style: TextStyle(fontSize: 12, color: _w54))),
                  SizedBox(width: 8),
                  SizedBox(width: 52, child: Text('Reps', style: TextStyle(fontSize: 12, color: _w54))),
                  SizedBox(width: 8),
                  Text('Weight', style: TextStyle(fontSize: 12, color: _w54)),
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
                    style: TextStyle(
                        fontSize: 13, color: _w60)),
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
                            style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: _w60)),
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
                                  : _w60,
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
            style: TextStyle(
                fontSize: 13, color: _w54, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          if (widget.comments.isEmpty)
            Text('No comments yet.',
                style: TextStyle(fontSize: 13, color: _w38))
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
                                style: TextStyle(
                                    fontSize: 11, color: _w38)),
                          ]),
                          const SizedBox(height: 3),
                          Text(comment.text,
                              style: TextStyle(
                                  fontSize: 14, color: _wt)),
                        ],
                      ),
                    ),
                    if (isOwn)
                      GestureDetector(
                        onTap: () => widget.onDeleteComment(e.key),
                        child: Icon(Icons.close,
                            size: 14, color: _w38),
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
                Expanded(
                  child: Text('Weight Calculator',
                      style: TextStyle(fontSize: 12, color: _w54)),
                ),
                Icon(
                  _expanded ? Icons.expand_less : Icons.expand_more,
                  size: 18,
                  color: _w38,
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
                                      : _w54,
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
