import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'firebase_options.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(const LiftTrackerApp());
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
  Map<int, RepRecord> bests;

  Lift({required this.name, Map<int, RepRecord>? bests}) : bests = bests ?? {};

  Map<String, dynamic> toJson() => {
        'name': name,
        'bests': bests.map((k, v) => MapEntry(k.toString(), v.toJson())),
      };

  factory Lift.fromJson(Map<String, dynamic> j) => Lift(
        name: j['name'] as String,
        bests: (j['bests'] as Map<String, dynamic>? ?? {}).map(
          (k, v) => MapEntry(
            int.parse(k),
            RepRecord.fromJson(v as Map<String, dynamic>),
          ),
        ),
      );
}

class Profile {
  String? id; // Firestore document ID
  String name;
  List<Lift> lifts;
  List<Workout> workouts;

  Profile({this.id, required this.name, List<Lift>? lifts, List<Workout>? workouts})
      : lifts = lifts ?? [],
        workouts = workouts ?? [];

  Map<String, dynamic> toJson() => {
        'name': name,
        'lifts': lifts.map((l) => l.toJson()).toList(),
        'workouts': workouts.map((w) => w.toJson()).toList(),
      };

  factory Profile.fromJson(Map<String, dynamic> j, {String? id}) => Profile(
        id: id,
        name: j['name'] as String,
        lifts: (j['lifts'] as List<dynamic>? ?? [])
            .map((e) => Lift.fromJson(e as Map<String, dynamic>))
            .toList(),
        workouts: (j['workouts'] as List<dynamic>? ?? [])
            .map((e) => Workout.fromJson(e as Map<String, dynamic>))
            .toList(),
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

class WorkoutExercise {
  final String liftName;
  final List<WorkoutSet> sets;

  WorkoutExercise({required this.liftName, List<WorkoutSet>? sets})
      : sets = sets ?? [];

  Map<String, dynamic> toJson() => {
        'liftName': liftName,
        'sets': sets.map((s) => s.toJson()).toList(),
      };

  factory WorkoutExercise.fromJson(Map<String, dynamic> j) => WorkoutExercise(
        liftName: j['liftName'] as String,
        sets: (j['sets'] as List<dynamic>? ?? [])
            .map((e) => WorkoutSet.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

class Workout {
  DateTime date;
  List<WorkoutExercise> exercises;

  Workout({required this.date, List<WorkoutExercise>? exercises})
      : exercises = exercises ?? [];

  Map<String, dynamic> toJson() => {
        'date': date.toIso8601String(),
        'exercises': exercises.map((e) => e.toJson()).toList(),
      };

  factory Workout.fromJson(Map<String, dynamic> j) => Workout(
        date: DateTime.parse(j['date'] as String),
        exercises: (j['exercises'] as List<dynamic>? ?? [])
            .map((e) => WorkoutExercise.fromJson(e as Map<String, dynamic>))
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
  const LiftTrackerApp({super.key});

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
      home: const ProfileScreen(),
    );
  }
}

// ─── Profile Screen ───────────────────────────────────────────────────────────

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

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
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
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
                        child: Text(
                          _initials(profile.name),
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                            color: Theme.of(context)
                                .colorScheme
                                .onPrimaryContainer,
                          ),
                        ),
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
  final VoidCallback onChanged;

  const HomeScreen({super.key, required this.profile, required this.onChanged});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<Lift> get lifts => widget.profile.lifts;

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.profile.name,
            style: const TextStyle(fontWeight: FontWeight.bold)),
        centerTitle: true,
      ),
      body: lifts.isEmpty
          ? const Center(
              child: Text(
                'No lifts yet.\nTap + to add your first lift.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16, color: Colors.white54),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: lifts.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, i) {
                final lift = lifts[i];
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
                  child: Card(
                    margin: EdgeInsets.zero,
                    child: ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
                      title: Text(lift.name,
                          style: const TextStyle(
                              fontSize: 18, fontWeight: FontWeight.w600)),
                      subtitle: Text(_subtitle(lift),
                          style: const TextStyle(
                              fontSize: 13, color: Colors.white60)),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () async {
                        await Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => LiftDetailScreen(
                              lift: lift,
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
            ),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FloatingActionButton.extended(
            heroTag: 'workout',
            onPressed: _logWorkout,
            icon: const Icon(Icons.fitness_center),
            label: const Text('Log Workout'),
          ),
          const SizedBox(height: 12),
          FloatingActionButton.extended(
            heroTag: 'lift',
            onPressed: _addLift,
            icon: const Icon(Icons.add),
            label: const Text('Add Lift'),
          ),
        ],
      ),
    );
  }
}

// ─── Lift Detail Screen ───────────────────────────────────────────────────────

class LiftDetailScreen extends StatefulWidget {
  final Lift lift;
  final VoidCallback onChanged;

  const LiftDetailScreen(
      {super.key, required this.lift, required this.onChanged});

  @override
  State<LiftDetailScreen> createState() => _LiftDetailScreenState();
}

class _LiftDetailScreenState extends State<LiftDetailScreen> {
  static const repOptions = [1, 2, 3, 4, 5, 6, 8, 10, 12, 15, 20];
  DateTime _selectedDate = DateTime.now();

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
    );
    if (picked != null) setState(() => _selectedDate = picked);
  }

  void _addOrEditRecord({RepRecord? existing, int? existingReps}) {
    int selectedReps = existingReps ?? 1;
    final weightController = TextEditingController(
      text: existing != null
          ? (existing.weight % 1 == 0
              ? existing.weight.toInt().toString()
              : existing.weight.toStringAsFixed(1))
          : '',
    );
    String unit = existing?.unit ?? 'lbs';
    if (existing != null) _selectedDate = existing.date;

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
              const SizedBox(height: 24),
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
                    widget.lift.bests[selectedReps] = RepRecord(
                      reps: selectedReps,
                      weight: w,
                      unit: unit,
                      date: _selectedDate,
                    );
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

  void _deleteRecord(int reps) {
    setState(() => widget.lift.bests.remove(reps));
    widget.onChanged();
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
    final sorted = widget.lift.bests.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));

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
      body: sorted.isEmpty
          ? const Center(
              child: Text(
                'No records yet.\nTap + to log a lift.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16, color: Colors.white54),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: sorted.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (_, i) {
                final entry = sorted[i];
                final reps = entry.key;
                final rec = entry.value;
                final w = rec.weight % 1 == 0
                    ? rec.weight.toInt().toString()
                    : rec.weight.toStringAsFixed(1);
                return Card(
                  margin: EdgeInsets.zero,
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 20, vertical: 10),
                    leading: Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        color:
                            Theme.of(context).colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        '${reps}RM',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                          color: Theme.of(context)
                              .colorScheme
                              .onPrimaryContainer,
                        ),
                      ),
                    ),
                    title: Text(
                      '$w ${rec.unit}',
                      style: const TextStyle(
                          fontSize: 22, fontWeight: FontWeight.bold),
                    ),
                    subtitle: Text(
                      _formatDate(rec.date),
                      style: const TextStyle(
                          fontSize: 12, color: Colors.white54),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.edit_outlined),
                          onPressed: () => _addOrEditRecord(
                              existing: rec, existingReps: reps),
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete_outline,
                              color: Colors.redAccent),
                          onPressed: () => _deleteRecord(reps),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addOrEditRecord(),
        icon: const Icon(Icons.add),
        label: const Text('Log Record'),
      ),
    );
  }
}

// ─── Workout Screen ───────────────────────────────────────────────────────────

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
  final List<WorkoutExercise> _exercises = [];
  static const _repOptions = [1, 2, 3, 4, 5, 6, 8, 10, 12, 15, 20];

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

  void _addExercises() {
    final already = _exercises.map((e) => e.liftName).toSet();
    final available =
        widget.profile.lifts.where((l) => !already.contains(l.name)).toList();
    if (available.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('All lifts already added.')),
      );
      return;
    }
    showDialog(
      context: context,
      builder: (_) => _ExercisePickerDialog(
        lifts: available,
        onSelected: (selected) => setState(() {
          for (final l in selected) {
            _exercises.add(WorkoutExercise(liftName: l.name));
          }
        }),
      ),
    );
  }

  void _addSet(WorkoutExercise exercise) {
    int selectedReps = 5;
    final weightCtrl = TextEditingController();
    String unit = 'lbs';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModal) => Padding(
          padding: EdgeInsets.fromLTRB(
              24, 24, 24, MediaQuery.of(ctx).viewInsets.bottom + 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Log Set — ${exercise.liftName}',
                style:
                    const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              const Text('Reps',
                  style: TextStyle(color: Colors.white60, fontSize: 13)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _repOptions.map((r) {
                  final sel = r == selectedReps;
                  return GestureDetector(
                    onTap: () => setModal(() => selectedReps = r),
                    child: Container(
                      width: 52,
                      height: 44,
                      decoration: BoxDecoration(
                        color: sel
                            ? Theme.of(context).colorScheme.primary
                            : Colors.white12,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        '$r',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: sel ? Colors.white : Colors.white70,
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
                      controller: weightCtrl,
                      autofocus: true,
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
                        setModal(() => unit = s.first),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: () {
                  final w = double.tryParse(weightCtrl.text.trim());
                  if (w == null || w <= 0) return;
                  Navigator.pop(ctx);
                  setState(() => exercise.sets
                      .add(WorkoutSet(reps: selectedReps, weight: w, unit: unit)));
                },
                child: const Text('Add Set', style: TextStyle(fontSize: 16)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _save() {
    widget.profile.workouts.add(Workout(date: _date, exercises: _exercises));
    widget.onSaved();
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title:
            const Text('New Workout', style: TextStyle(fontWeight: FontWeight.bold)),
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
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: OutlinedButton.icon(
              icon: const Icon(Icons.calendar_today_outlined, size: 18),
              label: Text(_fmt(_date)),
              onPressed: _pickDate,
              style: OutlinedButton.styleFrom(alignment: Alignment.centerLeft),
            ),
          ),
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
                    itemBuilder: (_, i) {
                      final ex = _exercises[i];
                      return Card(
                        margin: EdgeInsets.zero,
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      ex.liftName,
                                      style: const TextStyle(
                                          fontSize: 17,
                                          fontWeight: FontWeight.bold),
                                    ),
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.close, size: 20),
                                    onPressed: () =>
                                        setState(() => _exercises.removeAt(i)),
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints(),
                                  ),
                                ],
                              ),
                              if (ex.sets.isNotEmpty) ...[
                                const SizedBox(height: 8),
                                const Row(
                                  children: [
                                    SizedBox(
                                        width: 36,
                                        child: Text('Set',
                                            style: TextStyle(
                                                fontSize: 12,
                                                color: Colors.white54))),
                                    SizedBox(width: 8),
                                    SizedBox(
                                        width: 52,
                                        child: Text('Reps',
                                            style: TextStyle(
                                                fontSize: 12,
                                                color: Colors.white54))),
                                    SizedBox(width: 8),
                                    Text('Weight',
                                        style: TextStyle(
                                            fontSize: 12,
                                            color: Colors.white54)),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                ...ex.sets.asMap().entries.map((e) {
                                  final idx = e.key;
                                  final s = e.value;
                                  final w = s.weight % 1 == 0
                                      ? s.weight.toInt().toString()
                                      : s.weight.toStringAsFixed(1);
                                  return Padding(
                                    padding:
                                        const EdgeInsets.symmetric(vertical: 2),
                                    child: Row(
                                      children: [
                                        SizedBox(
                                          width: 36,
                                          child: Text(
                                            '${idx + 1}',
                                            style: TextStyle(
                                              fontSize: 14,
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .primary,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        SizedBox(
                                          width: 52,
                                          child: Text('${s.reps}',
                                              style: const TextStyle(
                                                  fontSize: 14)),
                                        ),
                                        const SizedBox(width: 8),
                                        Text('$w ${s.unit}',
                                            style: const TextStyle(
                                                fontSize: 14)),
                                        const Spacer(),
                                        GestureDetector(
                                          onTap: () => setState(
                                              () => ex.sets.removeAt(idx)),
                                          child: const Icon(Icons.close,
                                              size: 16,
                                              color: Colors.white38),
                                        ),
                                      ],
                                    ),
                                  );
                                }),
                              ],
                              const SizedBox(height: 12),
                              TextButton.icon(
                                icon: const Icon(Icons.add, size: 18),
                                label: const Text('Add Set'),
                                onPressed: () => _addSet(ex),
                                style: TextButton.styleFrom(
                                    padding: EdgeInsets.zero),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addExercises,
        icon: const Icon(Icons.add),
        label: const Text('Add Exercise'),
      ),
    );
  }
}

// ─── Exercise Picker Dialog ───────────────────────────────────────────────────

class _ExercisePickerDialog extends StatefulWidget {
  final List<Lift> lifts;
  final void Function(List<Lift>) onSelected;

  const _ExercisePickerDialog(
      {required this.lifts, required this.onSelected});

  @override
  State<_ExercisePickerDialog> createState() => _ExercisePickerDialogState();
}

class _ExercisePickerDialogState extends State<_ExercisePickerDialog> {
  final Set<int> _selected = {};

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Select Exercises'),
      content: SizedBox(
        width: double.maxFinite,
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: widget.lifts.length,
          itemBuilder: (_, i) => CheckboxListTile(
            title: Text(widget.lifts[i].name),
            value: _selected.contains(i),
            onChanged: (v) => setState(
                () => v == true ? _selected.add(i) : _selected.remove(i)),
          ),
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
                  widget.onSelected(
                      _selected.map((i) => widget.lifts[i]).toList());
                },
          child: const Text('Add'),
        ),
      ],
    );
  }
}
