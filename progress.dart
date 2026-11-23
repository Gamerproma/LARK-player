// ===========================================================================
// GESTOR DE PROGRESO
// Cuenta el tiempo en la app y el tiempo escuchando música, desbloquea los
// cosméticos y guarda qué está equipado. Todo se guarda en shared_preferences.
// ===========================================================================
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import 'cosmetics_catalog.dart';
import 'main.dart';

String fmtTime(num seconds) {
  final m = (seconds / 60).ceil();
  if (m < 1) return tr('menos de 1 min', 'under 1 min');
  if (m < 60) return '$m min';
  final h = m ~/ 60;
  final r = m % 60;
  return r == 0 ? '$h h' : '$h h $r min';
}

class ProgressManager extends ChangeNotifier with WidgetsBindingObserver {
  double appSec = 0;
  double listenSec = 0;
  final Set<String> unlocked = {};
  final Set<String> fresh = {}; // desbloqueados que aún no has visto
  final Map<String, String> equipped = {}; // categoría -> id
  int watchers = 0; // pantallas que están mirando el progreso
  Timer? _timer;
  DateTime _last = DateTime.now();
  bool _fg = true;
  int _ticks = 0;
  final Map<String, Cosmetic> _byId = {for (final c in kCosmetics) c.id: c};

  Future<void> init() async {
    final p = ctrl.prefs;
    appSec = p.getDouble('px_app') ?? 0;
    listenSec = p.getDouble('px_listen') ?? 0;
    unlocked.addAll(List<String>.from(jsonDecode(p.getString('px_unlocked') ?? '[]') as List));
    fresh.addAll(List<String>.from(jsonDecode(p.getString('px_new') ?? '[]') as List));
    final eq = jsonDecode(p.getString('px_equipped') ?? '{}') as Map<String, dynamic>;
    eq.forEach((k, v) => equipped[k] = v as String);
    _evaluate(silent: true);
    WidgetsBinding.instance.addObserver(this);
    _last = DateTime.now();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _fg = state == AppLifecycleState.resumed;
    if (!_fg) _save();
  }

  void _tick() {
    final now = DateTime.now();
    var d = now.difference(_last).inMilliseconds / 1000.0;
    _last = now;
    if (d > 5) d = 1; // por si el teléfono estuvo dormido
    if (_fg) appSec += d;
    if (ctrl.player.playing) listenSec += d;
    _ticks++;
    if (_ticks % 10 == 0) {
      _evaluate();
      _save();
    }
    if (watchers > 0) notifyListeners();
  }

  void _save() {
    final p = ctrl.prefs;
    p.setDouble('px_app', appSec);
    p.setDouble('px_listen', listenSec);
    p.setString('px_unlocked', jsonEncode(unlocked.toList()));
    p.setString('px_new', jsonEncode(fresh.toList()));
    p.setString('px_equipped', jsonEncode(equipped));
  }

  double have(Cosmetic c) => c.listen ? listenSec : appSec;
  bool isUnlocked(Cosmetic c) => unlocked.contains(c.id);
  double remaining(Cosmetic c) => max(0, c.minutes * 60 - have(c));
  double fraction(Cosmetic c) =>
      (have(c) / (c.minutes * 60)).clamp(0.0, 1.0).toDouble();

  static double max(double a, double b) => a > b ? a : b;

  String name(Cosmetic c) => tr(c.es, c.en);

  void _evaluate({bool silent = false}) {
    final newly = <Cosmetic>[];
    for (final c in kCosmetics) {
      if (unlocked.contains(c.id)) continue;
      if (have(c) >= c.minutes * 60) {
        unlocked.add(c.id);
        fresh.add(c.id);
        newly.add(c);
      }
    }
    if (newly.isEmpty) return;
    _save();
    notifyListeners();
    if (!silent) {
      final more = newly.length > 1 ? ' (+${newly.length - 1})' : '';
      messengerKey.currentState
        ?..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text(
              '${tr('¡Desbloqueaste', 'Unlocked')}: ${name(newly.first)}$more'),
          action: SnackBarAction(
            label: tr('Ver', 'View'),
            onPressed: () => openRewards(),
          ),
        ));
    }
  }

  /// El próximo elemento por desbloquear (el que menos tiempo necesita).
  Cosmetic? get next {
    Cosmetic? best;
    var bestRem = double.infinity;
    for (final c in kCosmetics) {
      if (unlocked.contains(c.id)) continue;
      final r = remaining(c);
      if (r < bestRem) {
        bestRem = r;
        best = c;
      }
    }
    return best;
  }

  // ----- Equipar -----
  Cosmetic? of(CosCat cat) {
    final id = equipped[cat.name];
    final c = id == null ? null : _byId[id];
    return (c != null && unlocked.contains(c.id)) ? c : null;
  }

  bool isEquipped(Cosmetic c) => equipped[c.cat.name] == c.id;

  void equip(Cosmetic c) {
    if (!unlocked.contains(c.id)) return;
    equipped[c.cat.name] = c.id;
    fresh.remove(c.id);
    _save();
    notifyListeners();
    ctrl.refreshUi();
  }

  void unequip(CosCat cat) {
    equipped.remove(cat.name);
    _save();
    notifyListeners();
    ctrl.refreshUi();
  }

  void markSeen() {
    if (fresh.isEmpty) return;
    fresh.clear();
    _save();
    notifyListeners();
  }

  Future<void> reset() async {
    appSec = 0;
    listenSec = 0;
    unlocked.clear();
    fresh.clear();
    equipped.clear();
    _save();
    notifyListeners();
    ctrl.refreshUi();
  }

  // Accesos rápidos para el resto de la app
  Cosmetic? get button => of(CosCat.button);
  Cosmetic? get vinyl => of(CosCat.vinyl);
  Cosmetic? get frame => of(CosCat.frame);
  Cosmetic? get viz => of(CosCat.viz);
  Cosmetic? get particles => of(CosCat.particles);
  Cosmetic? get theme => of(CosCat.theme);
  Cosmetic? get transition => of(CosCat.transition);
  Cosmetic? get title => of(CosCat.title);
  Color? get themeColor => theme == null ? null : Color(theme!.c1);
}

final progress = ProgressManager();
