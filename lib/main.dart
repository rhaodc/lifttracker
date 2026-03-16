import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
  String name;
  List<Lift> lifts;

  Profile({required this.name, List<Lift>? lifts}) : lifts = lifts ?? [];

  Map<String, dynamic> toJson() => {
        'name': name,
        'lifts': lifts.map((l) => l.toJson()).toList(),
      };

  factory Profile.fromJson(Map<String, dynamic> j) => Profile(
        name: j['name'] as String,
        lifts: (j['lifts'] as List<dynamic>? ?? [])
            .map((e) => Lift.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

// ─── Storage ─────────────────────────────────────────────────────────────────

class LiftStore {
  static const _key = 'profiles_v1';

  static Future<List<Profile>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return [];
    final list = jsonDecode(raw) as List<dynamic>;
    return list.map((e) => Profile.fromJson(e as Map<String, dynamic>)).toList();
  }

  static Future<void> save(List<Profile> profiles) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _key, jsonEncode(profiles.map((p) => p.toJson()).toList()));
  }
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
  List<Profile> profiles = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final loaded = await LiftStore.load();
    setState(() => profiles = loaded);
  }

  Future<void> _save() => LiftStore.save(profiles);

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
    setState(() => profiles.add(Profile(name: name)));
    _save();
  }

  void _deleteProfile(int index) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete profile?'),
        content: Text(
            'Remove "${profiles[index].name}" and all their lifts?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () {
              Navigator.pop(context);
              setState(() => profiles.removeAt(index));
              _save();
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
      body: profiles.isEmpty
          ? const Center(
              child: Text(
                'No profiles yet.\nTap + to create one.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16, color: Colors.white54),
              ),
            )
          : GridView.builder(
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
                  onTap: () async {
                    await Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => HomeScreen(
                          profile: profile,
                          onChanged: _save,
                        ),
                      ),
                    );
                    setState(() {});
                  },
                  onLongPress: () => _deleteProfile(i),
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
              separatorBuilder: (_, __) => const SizedBox(height: 8),
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
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addLift,
        icon: const Icon(Icons.add),
        label: const Text('Add Lift'),
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
                      date: DateTime.now(),
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
              separatorBuilder: (_, __) => const SizedBox(height: 8),
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
