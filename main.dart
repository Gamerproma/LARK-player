import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:app_settings/app_settings.dart';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:just_audio/just_audio.dart';
import 'package:on_audio_query_forked/on_audio_query.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart' as ph;
import 'package:photo_manager/photo_manager.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';
import 'package:webview_flutter/webview_flutter.dart';

late PlayMusicHandler audioHandler;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ctrl.init();
  audioHandler = await AudioService.init(
    builder: () => PlayMusicHandler(ctrl.player, ctrl.artFile),
    config: AudioServiceConfig(
      androidNotificationChannelId: 'com.mimusica.audio',
      androidNotificationChannelName: 'Play Music',
      androidNotificationChannelDescription:
          'Controles de reproducción de Play Music',
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: true,
      androidNotificationIcon: 'drawable/ic_notification',
      androidShowNotificationBadge: true,
    ),
  );
  runApp(const PlayMusicApp());
}

// ===========================================================================
// SESIÓN MULTIMEDIA DE ANDROID (notificación, pantalla de bloqueo, auriculares)
// ===========================================================================
class PlayMusicHandler extends BaseAudioHandler {
  final AudioPlayer _p;
  final Future<String?> Function(int msId) _artFile;
  List<MediaItem> _items = [];

  PlayMusicHandler(this._p, this._artFile) {
    _p.playbackEventStream.listen((_) => _emit());
    _p.playingStream.listen((_) => _emit());
    _p.currentIndexStream.listen(_onIndex);
    _p.durationStream.listen((d) {
      final i = _p.currentIndex;
      if (i == null || i >= _items.length || d == null) return;
      _items[i] = _items[i].copyWith(duration: d);
      mediaItem.add(_items[i]);
    });
  }

  /// Le pasa a Android la lista de canciones que están en la cola.
  void setItems(List<MediaItem> items) {
    _items = List.of(items);
    queue.add(_items);
  }

  void _emit() => playbackState.add(_state());

  PlaybackState _state() {
    return PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        if (_p.playing) MediaControl.pause else MediaControl.play,
        MediaControl.skipToNext,
      ],
      systemActions: const {MediaAction.seek},
      androidCompactActionIndices: const [0, 1, 2],
      processingState: const {
        ProcessingState.idle: AudioProcessingState.idle,
        ProcessingState.loading: AudioProcessingState.loading,
        ProcessingState.buffering: AudioProcessingState.buffering,
        ProcessingState.ready: AudioProcessingState.ready,
        ProcessingState.completed: AudioProcessingState.completed,
      }[_p.processingState]!,
      playing: _p.playing,
      updatePosition: _p.position,
      bufferedPosition: _p.bufferedPosition,
      speed: _p.speed,
      queueIndex: _p.currentIndex,
    );
  }

  void _onIndex(int? i) {
    if (i == null || i >= _items.length) return;
    mediaItem.add(_items[i]);
    _loadArt(i);
    _emit();
  }

  /// Guarda la carátula en un archivo temporal para mostrarla en la notificación.
  Future<void> _loadArt(int i) async {
    final item = _items[i];
    final id = item.extras?['msId'];
    if (id is! int || item.artUri != null) return;
    final path = await _artFile(id);
    if (path == null || i >= _items.length || _items[i].id != item.id) return;
    _items[i] = _items[i].copyWith(artUri: Uri.file(path));
    if (_p.currentIndex == i) mediaItem.add(_items[i]);
  }

  @override
  Future<void> play() => _p.play();
  @override
  Future<void> pause() => _p.pause();
  @override
  Future<void> seek(Duration position) => _p.seek(position);
  @override
  Future<void> skipToNext() => _p.seekToNext();
  @override
  Future<void> skipToPrevious() => _p.seekToPrevious();
  @override
  Future<void> skipToQueueItem(int index) =>
      _p.seek(Duration.zero, index: index);
  @override
  Future<void> stop() async {
    await _p.stop();
    return super.stop();
  }
}

// ===========================================================================
// DATOS Y UTILIDADES
// ===========================================================================
const accents = <Color>[
  Colors.deepPurple,
  Colors.blue,
  Colors.teal,
  Colors.pink,
  Colors.orange,
  Colors.green,
];

final messengerKey = GlobalKey<ScaffoldMessengerState>();

String tr(String es, String en) => ctrl.lang == 'es' ? es : en;
String lastSeg(String path) => path.split(RegExp(r'[\\/]')).last;

String fmt(Duration d) =>
    '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

void snack(BuildContext c, String m) {
  messengerKey.currentState
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(m)));
}

class Track {
  final int id;
  final int? msId; // id en la biblioteca de Android (null = descarga propia)
  final int? albumId;
  final String title;
  final String artist;
  final String path;
  final String uri;
  final int durationMs;
  final int addedMs;
  const Track({
    required this.id,
    required this.msId,
    required this.albumId,
    required this.title,
    required this.artist,
    required this.path,
    required this.uri,
    required this.durationMs,
    required this.addedMs,
  });
  String get folder {
    final i = path.lastIndexOf(RegExp(r'[\\/]'));
    return i <= 0 ? path : path.substring(0, i);
  }
}

class LyricLine {
  final Duration time;
  final String text;
  LyricLine(this.time, this.text);
}

class Lyrics {
  final List<LyricLine> lines;
  final bool synced;
  Lyrics(this.lines, this.synced);
}

Lyrics? parseLyrics(String raw) {
  final re = RegExp(r'\[(\d+):(\d+(?:\.\d+)?)\]');
  final tag = RegExp(r'^\[[a-zA-Z]+:');
  final timed = <LyricLine>[];
  final plain = <LyricLine>[];
  for (final l in raw.split('\n')) {
    final ms = re.allMatches(l).toList();
    if (ms.isEmpty) {
      final txt = l.trim();
      if (txt.isNotEmpty && !tag.hasMatch(txt)) {
        plain.add(LyricLine(Duration.zero, txt));
      }
      continue;
    }
    final text = l.replaceAll(re, '').trim();
    for (final m in ms) {
      final min = int.parse(m.group(1)!);
      final sec = double.parse(m.group(2)!);
      timed.add(LyricLine(
          Duration(milliseconds: ((min * 60 + sec) * 1000).round()), text));
    }
  }
  if (timed.isNotEmpty) {
    timed.sort((a, b) => a.time.compareTo(b.time));
    return Lyrics(timed, true);
  }
  if (plain.isNotEmpty) return Lyrics(plain, false);
  return null;
}

/// Saca el color más llamativo de una carátula y lo hace vibrante
/// (sin grises ni tonos oscuros) para el tema dinámico.
Future<Color?> dominantColor(Uint8List bytes) async {
  try {
    final codec = await ui.instantiateImageCodec(bytes, targetWidth: 56);
    final frame = await codec.getNextFrame();
    final data =
        await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
    frame.image.dispose();
    if (data == null) return null;
    const bins = 36; // grupos de 10 grados de tono
    final score = List<double>.filled(bins, 0);
    final hues = <double>[];
    final sats = <double>[];
    final lights = <double>[];
    final weights = <double>[];
    for (var i = 0; i + 3 < data.lengthInBytes; i += 4) {
      if (data.getUint8(i + 3) < 200) continue;
      final c = HSLColor.fromColor(Color.fromARGB(
          255, data.getUint8(i), data.getUint8(i + 1), data.getUint8(i + 2)));
      final s = c.saturation;
      final l = c.lightness;
      if (l < 0.12 || l > 0.94 || s < 0.15) continue; // fuera grises y extremos
      final w = (0.15 + s) * (1.0 - (l - 0.5).abs());
      hues.add(c.hue);
      sats.add(s);
      lights.add(l);
      weights.add(w);
      score[(c.hue / 10).floor() % bins] += w;
    }
    if (hues.length < 12) return null; // carátula casi gris: se usa el acento
    var best = 0;
    var bestScore = -1.0;
    for (var b = 0; b < bins; b++) {
      final sc = score[b] +
          0.6 * (score[(b + 1) % bins] + score[(b + bins - 1) % bins]);
      if (sc > bestScore) {
        bestScore = sc;
        best = b;
      }
    }
    final center = best * 10 + 5.0;
    double sw = 0, dh = 0, ss = 0, sl = 0;
    for (var i = 0; i < hues.length; i++) {
      final d = ((hues[i] - center + 540) % 360) - 180;
      if (d.abs() > 20) continue;
      final w = weights[i];
      sw += w;
      dh += d * w;
      ss += sats[i] * w;
      sl += lights[i] * w;
    }
    if (sw == 0) return null;
    final hue = (center + dh / sw + 360) % 360;
    final sat = (ss / sw * 1.3).clamp(0.6, 0.95).toDouble();
    final light = (sl / sw).clamp(0.42, 0.58).toDouble();
    return HSLColor.fromAHSL(1.0, hue, sat, light).toColor();
  } catch (_) {
    return null;
  }
}

// ===========================================================================
// CEREBRO DE LA APP
// ===========================================================================
class Controller extends ChangeNotifier {
  final equalizer = AndroidEqualizer();
  final loudness = AndroidLoudnessEnhancer();
  late final AudioPlayer player = AudioPlayer(
    audioPipeline: AudioPipeline(androidAudioEffects: [equalizer, loudness]),
  );
  final query = OnAudioQuery();
  late SharedPreferences prefs;

  List<Track> all = [];
  List<Track> tracks = [];
  List<Track> queue = [];
  Set<int> hidden = {};
  Set<int> deleted = {};
  Set<int> gone = {};
  Map<String, List<int>> playlists = {};
  Map<String, int> plays = {};
  String? bgPath;
  bool hasPermission = false;
  bool loading = true;
  bool videoActive = false;
  Color? coverColor;

  // Ajustes
  String lang = 'es';
  String themeMode = 'dark';
  int accent = 0;
  bool dynamicTheme = true;
  bool vinylOnRotate = true;
  bool rememberModes = true;
  int minSeconds = 30;
  double speed = 1.0;
  String sortMode = 'az';
  double dynIntensity = 0.75;
  int bgDim = 40;
  bool notifOk = true;
  bool notifBannerHidden = false;
  List<Map<String, String>> sites = [];
  DateTime? sleepEnd;
  Timer? _sleep;

  Track? get current {
    final i = player.currentIndex;
    if (i == null || i >= queue.length) return null;
    return queue[i];
  }

  Future<void> init() async {
    prefs = await SharedPreferences.getInstance();
    lang = prefs.getString('lang') ?? 'es';
    themeMode = prefs.getString('theme') ?? 'dark';
    accent = prefs.getInt('accent') ?? 0;
    dynamicTheme = prefs.getBool('dynamic') ?? true;
    vinylOnRotate = prefs.getBool('vinyl') ?? true;
    rememberModes = prefs.getBool('remember') ?? true;
    minSeconds = prefs.getInt('minSeconds') ?? 30;
    speed = prefs.getDouble('speed') ?? 1.0;
    sortMode = prefs.getString('sort') ?? 'az';
    dynIntensity = prefs.getDouble('dynIntensity') ?? 0.75;
    bgDim = prefs.getInt('bgDim') ?? 40;
    notifBannerHidden = prefs.getBool('notifBanner') ?? false;
    final st = prefs.getString('sites');
    if (st != null) {
      sites = (jsonDecode(st) as List)
          .map((e) => Map<String, String>.from(e as Map))
          .toList();
    }

    bgPath = prefs.getString('bg');
    if (bgPath != null && !File(bgPath!).existsSync()) bgPath = null;

    final pl = prefs.getString('playlists');
    if (pl != null) {
      final m = jsonDecode(pl) as Map<String, dynamic>;
      playlists = m.map((k, v) => MapEntry(k, List<int>.from(v)));
    }
    final pc = prefs.getString('plays');
    if (pc != null) {
      final m = jsonDecode(pc) as Map<String, dynamic>;
      plays = m.map((k, v) => MapEntry(k, v as int));
    }
    Set<int> readSet(String k) =>
        (jsonDecode(prefs.getString(k) ?? '[]') as List)
            .map((e) => e as int)
            .toSet();
    hidden = readSet('hidden');
    deleted = readSet('deleted');
    gone = readSet('gone');

    if (rememberModes) {
      final loop = prefs.getInt('loop') ?? 0;
      await player.setLoopMode(LoopMode.values[loop.clamp(0, 2)]);
      await player.setShuffleModeEnabled(prefs.getBool('shuffle') ?? false);
    }

    player.currentIndexStream.listen((i) {
      if (i != null && i < queue.length) {
        final k = '${queue[i].id}';
        plays[k] = (plays[k] ?? 0) + 1;
        prefs.setString('plays', jsonEncode(plays));
        _updateCover();
      }
      notifyListeners();
    });
  }

  // ----- Carátulas (con caché y buena calidad) -----
  final Map<String, Uint8List> _artCache = {};
  final Set<String> _artMissing = {};

  Uint8List? artSync(int id, int px) => _artCache['${id}_$px'];

  Future<Uint8List?> art(int id, int px, {int quality = 90}) async {
    final k = '${id}_$px';
    final c = _artCache[k];
    if (c != null) return c;
    if (_artMissing.contains(k)) return null;
    try {
      final b = await query.queryArtwork(
        id,
        ArtworkType.AUDIO,
        format: ArtworkFormat.JPEG,
        size: px,
        quality: quality,
      );
      if (b == null || b.isEmpty) {
        _artMissing.add(k);
        return null;
      }
      if (_artCache.length > 120) _artCache.remove(_artCache.keys.first);
      _artCache[k] = b;
      return b;
    } catch (_) {
      return null;
    }
  }

  /// Guarda la carátula como imagen en la caché y devuelve su ruta.
  Future<String?> artFile(int msId) async {
    try {
      final dir = await getTemporaryDirectory();
      final f = File('${dir.path}/art_$msId.jpg');
      if (await f.exists() && await f.length() > 0) return f.path;
      final b = await art(msId, 600, quality: 95);
      if (b == null) return null;
      await f.writeAsBytes(b, flush: true);
      return f.path;
    } catch (_) {
      return null;
    }
  }

  // Color vibrante listo para usar según la intensidad elegida
  Color? get glow {
    final c = coverColor;
    if (!dynamicTheme || c == null) return null;
    final h = HSLColor.fromColor(c);
    final sat = (h.saturation * (0.55 + 0.6 * dynIntensity)).clamp(0.0, 1.0);
    return h.withSaturation(sat.toDouble()).toColor();
  }

  int get glowAlpha => (60 + 180 * dynIntensity).round();

  int _colorFor = -1;
  Future<void> _updateCover() async {
    final t = current;
    if (t == null) return;
    _colorFor = t.id;
    if (t.msId == null) {
      if (coverColor != null) {
        coverColor = null;
        notifyListeners();
      }
      return;
    }
    final b = await art(t.msId!, 250);
    if (_colorFor != t.id) return;
    final c = b == null ? null : await dominantColor(b);
    if (_colorFor != t.id) return;
    coverColor = c;
    notifyListeners();
  }

  // ----- Permiso de notificaciones (Android 13+) -----
  Future<void> checkNotifications({bool ask = false}) async {
    try {
      var s = await ph.Permission.notification.status;
      if (!s.isGranted && ask) s = await ph.Permission.notification.request();
      notifOk = s.isGranted;
    } catch (_) {}
    notifyListeners();
  }

  void hideNotifBanner() {
    notifBannerHidden = true;
    prefs.setBool('notifBanner', true);
    notifyListeners();
  }

  // ----- Biblioteca -----
  Future<Directory> downloadsDir() async {
    final base = await getApplicationDocumentsDirectory();
    final d = Directory('${base.path}/Descargas');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  String _k(String s) => s.toLowerCase();

  void _refilter() {
    final l = all
        .where((t) =>
            !hidden.contains(t.id) &&
            !deleted.contains(t.id) &&
            !gone.contains(t.id) &&
            (t.msId == null || t.durationMs >= minSeconds * 1000))
        .toList();
    int byTitle(Track a, Track b) => _k(a.title).compareTo(_k(b.title));
    switch (sortMode) {
      case 'recent':
        l.sort((a, b) => b.addedMs.compareTo(a.addedMs));
        break;
      case 'plays':
        l.sort((a, b) {
          final c = (plays['${b.id}'] ?? 0).compareTo(plays['${a.id}'] ?? 0);
          return c != 0 ? c : byTitle(a, b);
        });
        break;
      case 'artist':
        l.sort((a, b) {
          final c = _k(a.artist).compareTo(_k(b.artist));
          return c != 0 ? c : byTitle(a, b);
        });
        break;
      case 'duration':
        l.sort((a, b) => b.durationMs.compareTo(a.durationMs));
        break;
      default:
        l.sort(byTitle);
    }
    tracks = l;
  }

  void setSort(String v) {
    sortMode = v;
    prefs.setString('sort', v);
    _refilter();
    notifyListeners();
  }

  Future<void> loadSongs() async {
    loading = true;
    notifyListeners();
    hasPermission = await query.permissionsStatus();
    if (!hasPermission) hasPermission = await query.permissionsRequest();
    final list = <Track>[];
    if (hasPermission) {
      final songs = await query.querySongs(
        sortType: SongSortType.TITLE,
        orderType: OrderType.ASC_OR_SMALLER,
        uriType: UriType.EXTERNAL,
        ignoreCase: true,
      );
      for (final s in songs) {
        if (s.uri == null) continue;
        final art = s.artist;
        list.add(Track(
          id: s.id,
          msId: s.id,
          albumId: s.albumId,
          title: s.title,
          artist: (art == null || art == '<unknown>')
              ? tr('Desconocido', 'Unknown')
              : art,
          path: s.data,
          uri: s.uri!,
          durationMs: s.duration ?? 0,
          addedMs: (s.dateAdded ?? 0) * 1000,
        ));
      }
    }
    try {
      final dir = await downloadsDir();
      const exts = ['.mp3', '.m4a', '.aac', '.wav', '.ogg', '.flac', '.opus'];
      for (final f in dir.listSync()) {
        if (f is! File) continue;
        final low = f.path.toLowerCase();
        if (!exts.any((e) => low.endsWith(e))) continue;
        final name = lastSeg(f.path);
        final dot = name.lastIndexOf('.');
        list.add(Track(
          id: -((f.path.hashCode.abs() % 1000000000) + 1),
          msId: null,
          albumId: null,
          title: dot > 0 ? name.substring(0, dot) : name,
          artist: tr('Descargas', 'Downloads'),
          path: f.path,
          uri: Uri.file(f.path).toString(),
          durationMs: 0,
          addedMs: f.lastModifiedSync().millisecondsSinceEpoch,
        ));
      }
    } catch (_) {}
    all = list;
    _refilter();
    loading = false;
    notifyListeners();
  }

  // ----- Reproducción -----
  Future<void> playList(List<Track> list, int index) async {
    if (list.isEmpty) return;
    queue = List.of(list);
    audioHandler.setItems(queue
        .map((t) => MediaItem(
              id: '${t.id}',
              title: t.title,
              artist: t.artist,
              duration:
                  t.durationMs > 0 ? Duration(milliseconds: t.durationMs) : null,
              extras: {'msId': t.msId},
            ))
        .toList());
    final sources = queue.map((t) => AudioSource.uri(Uri.parse(t.uri))).toList();
    try {
      await player.setAudioSource(
        ConcatenatingAudioSource(children: sources),
        initialIndex: index,
      );
      await player.setSpeed(speed);
      player.play();
      _restoreEq();
    } catch (_) {}
  }

  Future<void> playTrack(Track t) async {
    final i = tracks.indexWhere((x) => x.id == t.id);
    if (i < 0) {
      await playList([t], 0);
    } else {
      await playList(tracks, i);
    }
  }

  Future<void> playIfNeeded(Track t) async {
    if (current?.id != t.id) await playTrack(t);
  }

  Future<void> playAllShuffled() async {
    if (tracks.isEmpty) return;
    await playList(tracks, Random().nextInt(tracks.length));
    await player.shuffle();
    await player.setShuffleModeEnabled(true);
    prefs.setBool('shuffle', true);
    notifyListeners();
  }

  Future<void> toggleShuffle() async {
    final on = !player.shuffleModeEnabled;
    if (on) await player.shuffle();
    await player.setShuffleModeEnabled(on);
    prefs.setBool('shuffle', on);
    notifyListeners();
  }

  Future<void> cycleRepeat() async {
    final next = {
      LoopMode.off: LoopMode.all,
      LoopMode.all: LoopMode.one,
      LoopMode.one: LoopMode.off,
    }[player.loopMode]!;
    await player.setLoopMode(next);
    prefs.setInt('loop', next.index);
    notifyListeners();
  }

  Future<void> setSpeed(double v) async {
    speed = v;
    await player.setSpeed(v);
    prefs.setDouble('speed', v);
    notifyListeners();
  }

  void setSleep(int? minutes) {
    _sleep?.cancel();
    _sleep = null;
    sleepEnd = null;
    if (minutes != null) {
      sleepEnd = DateTime.now().add(Duration(minutes: minutes));
      _sleep = Timer(Duration(minutes: minutes), () {
        player.pause();
        sleepEnd = null;
        notifyListeners();
      });
    }
    notifyListeners();
  }

  void setVideoActive(bool v) {
    videoActive = v;
    WidgetsBinding.instance.addPostFrameCallback((_) => notifyListeners());
  }

  // ----- Ecualizador (se guarda y se restaura) -----
  bool _eqRestored = false;
  bool eqOn = false;

  Future<void> _restoreEq() async {
    if (_eqRestored) return;
    _eqRestored = true;
    try {
      final s = prefs.getString('eq');
      if (s == null) return;
      final m = jsonDecode(s) as Map<String, dynamic>;
      final p = await equalizer.parameters;
      final g = (m['g'] as List).map((e) => (e as num).toDouble()).toList();
      for (var i = 0; i < min(g.length, p.bands.length); i++) {
        await p.bands[i].setGain(g[i]);
      }
      eqOn = m['on'] == true;
      await equalizer.setEnabled(eqOn);
      final lg = (m['lg'] as num?)?.toDouble() ?? 0;
      await loudness.setTargetGain(lg);
      await loudness.setEnabled(lg > 0);
    } catch (_) {}
  }

  void saveEq(List<double> gains, double loud) {
    prefs.setString(
      'eq',
      jsonEncode({'g': gains, 'on': eqOn, 'lg': loud}),
    );
  }

  Future<void> setEqEnabled(bool v) async {
    eqOn = v;
    try {
      await equalizer.setEnabled(v);
    } catch (_) {}
    final m = jsonDecode(prefs.getString('eq') ?? '{}') as Map<String, dynamic>;
    m['on'] = v;
    prefs.setString('eq', jsonEncode(m));
    notifyListeners();
  }

  // ----- Ajustes -----
  void setLang(String v) {
    lang = v;
    prefs.setString('lang', v);
    notifyListeners();
  }

  void setTheme(String v) {
    themeMode = v;
    prefs.setString('theme', v);
    notifyListeners();
  }

  void setAccent(int v) {
    accent = v;
    prefs.setInt('accent', v);
    notifyListeners();
  }

  void setDynamic(bool v) {
    dynamicTheme = v;
    prefs.setBool('dynamic', v);
    notifyListeners();
  }

  void setIntensity(double v) {
    dynIntensity = v;
    prefs.setDouble('dynIntensity', v);
    notifyListeners();
  }

  void setBgDim(int v) {
    bgDim = v;
    prefs.setInt('bgDim', v);
    notifyListeners();
  }

  // ----- Mis sitios (accesos directos del buscador) -----
  void addSite(String name, String url) {
    sites.add({'n': name, 'u': url});
    prefs.setString('sites', jsonEncode(sites));
    notifyListeners();
  }

  void removeSite(int i) {
    if (i < 0 || i >= sites.length) return;
    sites.removeAt(i);
    prefs.setString('sites', jsonEncode(sites));
    notifyListeners();
  }

  void setVinyl(bool v) {
    vinylOnRotate = v;
    prefs.setBool('vinyl', v);
    notifyListeners();
  }

  void setRemember(bool v) {
    rememberModes = v;
    prefs.setBool('remember', v);
    notifyListeners();
  }

  void setMinSeconds(int v) {
    minSeconds = v;
    prefs.setInt('minSeconds', v);
    _refilter();
    notifyListeners();
  }

  // ----- Ocultar / borrar -----
  void _saveSets() {
    prefs.setString('hidden', jsonEncode(hidden.toList()));
    prefs.setString('deleted', jsonEncode(deleted.toList()));
    prefs.setString('gone', jsonEncode(gone.toList()));
    _refilter();
    notifyListeners();
  }

  void hide(Track t) {
    hidden.add(t.id);
    _saveSets();
  }

  void unhide(int id) {
    hidden.remove(id);
    _saveSets();
  }

  void softDelete(Track t) {
    deleted.add(t.id);
    _saveSets();
  }

  void restore(int id) {
    deleted.remove(id);
    _saveSets();
  }

  /// Borra el archivo de verdad. Devuelve false si Android no lo permitió.
  Future<bool> deleteFile(Track t) async {
    var ok = false;
    try {
      final f = File(t.path);
      if (await f.exists()) await f.delete();
      ok = !(await File(t.path).exists());
    } catch (_) {}
    if (!ok && t.msId != null) {
      try {
        final r = await PhotoManager.editor.deleteWithIds(['${t.msId}']);
        ok = r.isNotEmpty;
      } catch (_) {}
    }
    if (ok) {
      gone.add(t.id);
      deleted.remove(t.id);
      hidden.remove(t.id);
      all.removeWhere((x) => x.id == t.id);
      for (final l in playlists.values) {
        l.remove(t.id);
      }
      prefs.setString('playlists', jsonEncode(playlists));
      _saveSets();
    }
    return ok;
  }

  // ----- Fondo -----
  Future<void> pickBackground() async {
    final x = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (x == null) return;
    final dir = await getApplicationDocumentsDirectory();
    final dest =
        '${dir.path}/fondo_${DateTime.now().millisecondsSinceEpoch}.jpg';
    await File(x.path).copy(dest);
    if (bgPath != null) {
      try {
        File(bgPath!).deleteSync();
      } catch (_) {}
    }
    bgPath = dest;
    await prefs.setString('bg', dest);
    notifyListeners();
  }

  Future<void> clearBackground() async {
    bgPath = null;
    await prefs.remove('bg');
    notifyListeners();
  }

  // ----- Listas -----
  void _savePlaylists() {
    prefs.setString('playlists', jsonEncode(playlists));
    notifyListeners();
  }

  void createPlaylist(String name) {
    if (name.isEmpty || playlists.containsKey(name)) return;
    playlists[name] = [];
    _savePlaylists();
  }

  void deletePlaylist(String name) {
    playlists.remove(name);
    _savePlaylists();
  }

  void addToPlaylist(String name, int id) {
    final l = playlists[name];
    if (l == null || l.contains(id)) return;
    l.add(id);
    _savePlaylists();
  }

  void removeFromPlaylist(String name, int id) {
    playlists[name]?.remove(id);
    _savePlaylists();
  }

  // ----- Letras -----
  Future<Lyrics?> loadLyrics(Track t, {bool forceOnline = false}) async {
    if (!forceOnline) {
      final saved = prefs.getString('lyr_${t.id}');
      if (saved != null) return parseLyrics(saved);
      try {
        final dot = t.path.lastIndexOf('.');
        final base = dot > 0 ? t.path.substring(0, dot) : t.path;
        final f = File('$base.lrc');
        if (await f.exists()) return parseLyrics(await f.readAsString());
      } catch (_) {}
      return null;
    }
    final text = await _fetchOnline(t);
    if (text == null) return null;
    await prefs.setString('lyr_${t.id}', text);
    return parseLyrics(text);
  }

  Future<void> saveLyrics(Track t, String text) async {
    await prefs.setString('lyr_${t.id}', text);
  }

  Future<String?> _fetchOnline(Track t) async {
    final client = HttpClient();
    try {
      final params = <String, String>{'track_name': t.title};
      if (t.artist != tr('Desconocido', 'Unknown') &&
          t.artist != tr('Descargas', 'Downloads')) {
        params['artist_name'] = t.artist;
      }
      final u = Uri.https('lrclib.net', '/api/search', params);
      final req = await client.getUrl(u);
      req.headers.set('User-Agent', 'PlayMusic/3.0');
      final res = await req.close().timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return null;
      final body = await res.transform(utf8.decoder).join();
      final data = jsonDecode(body);
      if (data is! List || data.isEmpty) return null;
      for (final item in data) {
        final s = item['syncedLyrics'];
        if (s is String && s.trim().isNotEmpty) return s;
      }
      for (final item in data) {
        final p = item['plainLyrics'];
        if (p is String && p.trim().isNotEmpty) return p;
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

}

final ctrl = Controller();

// ===========================================================================
// APP Y PANTALLA PRINCIPAL
// ===========================================================================
ThemeData buildTheme(Brightness b) {
  final seed = ctrl.glow ?? accents[ctrl.accent];
  return ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(seedColor: seed, brightness: b),
  );
}

class PlayMusicApp extends StatelessWidget {
  const PlayMusicApp({super.key});

  ThemeData _theme(Brightness b) => buildTheme(b);

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ctrl,
      builder: (context, _) => MaterialApp(
        title: 'Play Music',
        debugShowCheckedModeBanner: false,
        scaffoldMessengerKey: messengerKey,
        theme: _theme(Brightness.light),
        darkTheme: _theme(Brightness.dark),
        themeMode: ctrl.themeMode == 'light'
            ? ThemeMode.light
            : ctrl.themeMode == 'system'
                ? ThemeMode.system
                : ThemeMode.dark,
        builder: (context, child) {
          final landscape =
              MediaQuery.of(context).orientation == Orientation.landscape;
          final showVinyl = ctrl.vinylOnRotate &&
              landscape &&
              ctrl.current != null &&
              !ctrl.videoActive;
          return Stack(
            children: [
              child!,
              if (showVinyl) const Positioned.fill(child: VinylView()),
            ],
          );
        },
        home: const Root(),
      ),
    );
  }
}

class Root extends StatefulWidget {
  const Root({super.key});
  @override
  State<Root> createState() => _RootState();
}

class _RootState extends State<Root> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ctrl.loadSongs().then((_) => ctrl.checkNotifications(ask: true));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) ctrl.checkNotifications();
  }

  /// Capa de fondo: si hay foto propia, SOLO se le pone una capa oscura
  /// semitransparente (ajustable). El color dinámico no la tapa.
  Widget _background(ColorScheme cs) {
    if (ctrl.bgPath != null) {
      return Stack(
        fit: StackFit.expand,
        children: [
          Image.file(
            File(ctrl.bgPath!),
            fit: BoxFit.cover,
            filterQuality: FilterQuality.medium,
            gaplessPlayback: true,
          ),
          Container(color: Colors.black.withAlpha((ctrl.bgDim * 2.55).round())),
        ],
      );
    }
    final g = ctrl.glow;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 600),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            g != null
                ? g.withAlpha((ctrl.glowAlpha * 0.75).round())
                : cs.primary.withAlpha(40),
            cs.surface,
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ctrl,
      builder: (context, _) {
        if (ctrl.loading && ctrl.all.isEmpty) return const SplashScreen();
        final cs = Theme.of(context).colorScheme;
        final hasBg = ctrl.bgPath != null;
        return Theme(
          // Con foto de fondo se usa el tema oscuro para que el texto se lea bien
          data: hasBg ? buildTheme(Brightness.dark) : Theme.of(context),
          child: Stack(
            fit: StackFit.expand,
            children: [
              _background(cs),
              DefaultTabController(
                length: 5,
                initialIndex: 1,
                child: Scaffold(
                  backgroundColor: Colors.transparent,
                  appBar: AppBar(
                    backgroundColor: Colors.transparent,
                    surfaceTintColor: Colors.transparent,
                    scrolledUnderElevation: 0,
                    title: const Row(
                      children: [
                        PlayLogo(size: 30),
                        SizedBox(width: 10),
                        Text('Play Music',
                            style: TextStyle(fontWeight: FontWeight.bold)),
                      ],
                    ),
                    actions: [
                      IconButton(
                        icon: const Icon(Icons.search),
                        tooltip: tr('Buscar', 'Search'),
                        onPressed: () => Navigator.push(
                          context,
                          MaterialPageRoute(builder: (_) => const SearchPage()),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.settings),
                        tooltip: tr('Ajustes', 'Settings'),
                        onPressed: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => const SettingsPage()),
                        ),
                      ),
                    ],
                    bottom: TabBar(
                      isScrollable: true,
                      tabAlignment: TabAlignment.start,
                      dividerColor: Colors.transparent,
                      tabs: [
                        const Tab(text: 'Videos'),
                        Tab(text: tr('Canciones', 'Songs')),
                        const Tab(text: 'Playlists'),
                        Tab(text: tr('Carpetas', 'Folders')),
                        Tab(text: tr('Artistas', 'Artists')),
                      ],
                    ),
                  ),
                  body: const TabBarView(
                    children: [
                      VideosTab(),
                      SongsTab(),
                      PlaylistsTab(),
                      GroupTab(isFolder: true),
                      GroupTab(isFolder: false),
                    ],
                  ),
                  bottomNavigationBar: const MiniPlayer(),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ===========================================================================
// LOGO, BARRAS ANIMADAS Y PANTALLA DE CARGA
// ===========================================================================
class _LogoPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    final rect = Rect.fromLTWH(0, 0, s, s);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(s * 0.22)),
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF7C3AED), Color(0xFFEC4899)],
        ).createShader(rect),
    );
    final c = Offset(s * 0.5, s * 0.45);
    final r = s * 0.30;
    canvas.drawCircle(c, r, Paint()..color = const Color(0xFF111118));
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = max(1.0, s * 0.004)
      ..color = const Color(0xFF343442);
    for (final k in [0.88, 0.76, 0.64]) {
      canvas.drawCircle(c, r * k, ring);
    }
    final lr = r * 0.52;
    final lrect = Rect.fromCircle(center: c, radius: lr);
    canvas.drawCircle(
      c,
      lr,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFFBBF24), Color(0xFFF97316)],
        ).createShader(lrect),
    );
    final t = lr * 0.62;
    final tri = Path()
      ..moveTo(c.dx - t * 0.55, c.dy - t)
      ..lineTo(c.dx - t * 0.55, c.dy + t)
      ..lineTo(c.dx + t * 0.95, c.dy)
      ..close();
    canvas.drawPath(tri, Paint()..color = Colors.white);
    const heights = [0.05, 0.09, 0.14, 0.085, 0.05];
    final bw = s * 0.055;
    final gap = s * 0.095;
    final base = s * 0.925;
    for (var i = 0; i < heights.length; i++) {
      final x = s * 0.5 - gap * 2 + gap * i;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(x - bw / 2, base - s * heights[i], x + bw / 2, base),
          Radius.circular(bw / 2),
        ),
        Paint()..color = Colors.white.withAlpha(235),
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class PlayLogo extends StatelessWidget {
  final double size;
  const PlayLogo({super.key, required this.size});
  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size(size, size), painter: _LogoPainter());
}

class MusicBars extends StatefulWidget {
  final int count;
  final double width;
  final double height;
  final Color? color;
  final bool animate;
  const MusicBars({
    super.key,
    this.count = 5,
    this.width = 40,
    this.height = 40,
    this.color,
    this.animate = true,
  });
  @override
  State<MusicBars> createState() => _MusicBarsState();
}

class _MusicBarsState extends State<MusicBars>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1400))
    ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? Theme.of(context).colorScheme.primary;
    final barW = widget.width / (widget.count * 1.6);
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) => SizedBox(
        width: widget.width,
        height: widget.height,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (int i = 0; i < widget.count; i++)
              Container(
                width: barW,
                height: widget.animate
                    ? widget.height *
                        (0.2 +
                            0.8 *
                                (0.5 +
                                    0.5 *
                                        sin(2 * pi * _c.value * (1 + i % 3) +
                                            i * 1.3)))
                    : widget.height * 0.2,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(barW / 2),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class MusicLoader extends StatelessWidget {
  final String? text;
  const MusicLoader({super.key, this.text});
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const MusicBars(count: 7, width: 90, height: 56),
          const SizedBox(height: 16),
          Text(text ?? tr('Cargando tu música...', 'Loading your music...')),
        ],
      ),
    );
  }
}

class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF1E0A46), Color(0xFF7A1B5E)],
          ),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TweenAnimationBuilder<double>(
                tween: Tween(begin: 0.6, end: 1.0),
                duration: const Duration(milliseconds: 900),
                curve: Curves.elasticOut,
                builder: (context, v, child) =>
                    Transform.scale(scale: v, child: child),
                child: const PlayLogo(size: 130),
              ),
              const SizedBox(height: 20),
              const Text(
                'Play Music',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 30,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 28),
              const MusicBars(
                  count: 9, width: 110, height: 52, color: Color(0xFFFBBF24)),
              const SizedBox(height: 14),
              Text(
                tr('Cargando tu música...', 'Loading your music...'),
                style: const TextStyle(color: Colors.white70),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ===========================================================================
// CARÁTULAS NÍTIDAS
// ===========================================================================
class TrackArt extends StatelessWidget {
  final Track track;
  final double size;
  final double radius;
  const TrackArt({
    super.key,
    required this.track,
    required this.size,
    this.radius = 8,
  });

  Widget _ph(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Theme.of(context).colorScheme.primaryContainer,
              Theme.of(context).colorScheme.secondaryContainer,
            ],
          ),
        ),
        child: Icon(Icons.music_note, size: size * 0.5),
      );

  @override
  Widget build(BuildContext context) {
    if (track.msId == null) return _ph(context);
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final px = size > 100 ? 1000 : 300;
    Widget img(Uint8List b) => ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: Image.memory(
            b,
            width: size,
            height: size,
            fit: BoxFit.cover,
            cacheWidth: (size * dpr).round(),
            filterQuality: FilterQuality.high,
            isAntiAlias: true,
            gaplessPlayback: true,
          ),
        );
    final cached = ctrl.artSync(track.msId!, px);
    if (cached != null) return img(cached);
    return FutureBuilder<Uint8List?>(
      future: ctrl.art(track.msId!, px, quality: size > 100 ? 100 : 92),
      builder: (context, s) => s.data != null ? img(s.data!) : _ph(context),
    );
  }
}

class PlayPauseButton extends StatelessWidget {
  final double size;
  const PlayPauseButton({super.key, this.size = 32});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<bool>(
      stream: ctrl.player.playingStream,
      builder: (context, snap) {
        final playing = snap.data ?? false;
        return IconButton(
          iconSize: size,
          icon: Icon(playing ? Icons.pause_circle : Icons.play_circle),
          onPressed: playing ? ctrl.player.pause : ctrl.player.play,
        );
      },
    );
  }
}

// ===========================================================================
// DIÁLOGOS Y MENÚ DE TRES PUNTOS
// ===========================================================================
Future<String?> askName(BuildContext context) {
  final t = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(tr('Nombre de la lista', 'Playlist name')),
      content: TextField(controller: t, autofocus: true),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(tr('Cancelar', 'Cancel')),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, t.text.trim()),
          child: Text(tr('Crear', 'Create')),
        ),
      ],
    ),
  );
}

void addToPlaylistSheet(BuildContext context, Track s) {
  showModalBottomSheet(
    context: context,
    builder: (ctx) => ListView(
      children: [
        ListTile(
          leading: const Icon(Icons.add),
          title: Text(tr('Nueva lista', 'New playlist')),
          onTap: () async {
            Navigator.pop(ctx);
            final name = await askName(context);
            if (name != null && name.isNotEmpty) {
              ctrl.createPlaylist(name);
              ctrl.addToPlaylist(name, s.id);
            }
          },
        ),
        for (final n in ctrl.playlists.keys)
          ListTile(
            leading: const Icon(Icons.queue_music),
            title: Text(n),
            onTap: () {
              ctrl.addToPlaylist(n, s.id);
              Navigator.pop(ctx);
            },
          ),
      ],
    ),
  );
}

void showSleepDialog(BuildContext context) {
  showDialog(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: Text(tr('Temporizador para dormir', 'Sleep timer')),
      children: [
        for (final m in [15, 30, 45, 60, 90])
          SimpleDialogOption(
            onPressed: () {
              ctrl.setSleep(m);
              Navigator.pop(ctx);
            },
            child: Text('$m min'),
          ),
        if (ctrl.sleepEnd != null)
          SimpleDialogOption(
            onPressed: () {
              ctrl.setSleep(null);
              Navigator.pop(ctx);
            },
            child: Text(tr('Cancelar temporizador', 'Cancel timer')),
          ),
      ],
    ),
  );
}

void showSpeedDialog(BuildContext context) {
  showDialog(
    context: context,
    builder: (ctx) {
      double v = ctrl.speed;
      return StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: Text(tr('Velocidad de reproducción', 'Playback speed')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('${v.toStringAsFixed(2)}x'),
              Slider(
                value: v,
                min: 0.5,
                max: 2.0,
                divisions: 30,
                onChanged: (x) => set(() => v = x),
                onChangeEnd: ctrl.setSpeed,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                set(() => v = 1.0);
                ctrl.setSpeed(1.0);
              },
              child: const Text('1.0x'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(tr('Cerrar', 'Close')),
            ),
          ],
        ),
      );
    },
  );
}

Future<void> handleTrackAction(
    BuildContext context, String action, Track t) async {
  switch (action) {
    case 'playlist':
      addToPlaylistSheet(context, t);
      break;
    case 'share':
      try {
        await Share.shareXFiles([XFile(t.path)], text: t.title);
      } catch (_) {
        snack(context, tr('No pude compartir este archivo.',
            'Could not share this file.'));
      }
      break;
    case 'viz':
      await ctrl.playIfNeeded(t);
      if (context.mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const VisualizerPage()),
        );
      }
      break;
    case 'speed':
      showSpeedDialog(context);
      break;
    case 'ringtone':
      snack(
        context,
        tr('Android no deja cambiar tonos desde aquí. En Sonido, elige "Tono de llamada" y busca esta canción.',
            'Android does not allow this from here. In Sound settings pick "Ringtone" and look for this song.'),
      );
      try {
        await AppSettings.openAppSettings(type: AppSettingsType.sound);
      } catch (_) {}
      break;
    case 'timer':
      showSleepDialog(context);
      break;
    case 'hide':
      ctrl.hide(t);
      snack(context, tr('Canción oculta. Puedes mostrarla en Ajustes.',
          'Song hidden. You can show it again in Settings.'));
      break;
    case 'delete':
      final r = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(tr('¿Borrar esta canción?', 'Delete this song?')),
          content: Text(tr(
              'Puedes borrar el archivo del teléfono o solo enviarla a "Eliminados recientemente" (se puede recuperar).',
              'You can delete the file from the phone or just send it to "Recently deleted" (can be restored).')),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'no'),
              child: Text(tr('Cancelar', 'Cancel')),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'trash'),
              child: Text(tr('A eliminados', 'To deleted')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, 'file'),
              child: Text(tr('Borrar archivo', 'Delete file')),
            ),
          ],
        ),
      );
      if (r == 'trash') {
        ctrl.softDelete(t);
        snack(context, tr('Enviada a Eliminados recientemente.',
            'Sent to Recently deleted.'));
      } else if (r == 'file') {
        final ok = await ctrl.deleteFile(t);
        if (ok) {
          snack(context, tr('Canción borrada del teléfono.',
              'Song deleted from the phone.'));
        } else {
          ctrl.softDelete(t);
          snack(
            context,
            tr('Android no permitió borrar el archivo. La envié a Eliminados recientemente.',
                'Android did not allow deleting the file. Sent to Recently deleted.'),
          );
        }
      }
      break;
  }
}

PopupMenuItem<String> _item(String v, IconData i, String label) {
  return PopupMenuItem<String>(
    value: v,
    child: Row(
      children: [
        Icon(i, size: 20),
        const SizedBox(width: 12),
        Expanded(child: Text(label)),
      ],
    ),
  );
}

Widget trackMenu(BuildContext context, Track t) {
  return PopupMenuButton<String>(
    icon: const Icon(Icons.more_vert),
    onSelected: (a) => handleTrackAction(context, a, t),
    itemBuilder: (_) => [
      _item('playlist', Icons.playlist_add,
          tr('Agregar a lista de reproducción', 'Add to playlist')),
      _item('share', Icons.share, tr('Compartir', 'Share')),
      _item('viz', Icons.graphic_eq,
          tr('Visualizador de música', 'Music visualizer')),
      _item('speed', Icons.speed,
          tr('Velocidad de reproducción', 'Playback speed')),
      _item('ringtone', Icons.notifications_active,
          tr('Establecer como tono de llamada', 'Set as ringtone')),
      _item('timer', Icons.timer, tr('Temporizador', 'Timer')),
      _item('hide', Icons.visibility_off, tr('Ocultar', 'Hide')),
      _item('delete', Icons.delete_outline, tr('Borrar', 'Delete')),
    ],
  );
}

// ===========================================================================
// FILA DE CANCIÓN (resalta la que está sonando)
// ===========================================================================
class TrackTile extends StatelessWidget {
  final Track track;
  final VoidCallback onTap;
  final Widget? trailing;
  const TrackTile({
    super.key,
    required this.track,
    required this.onTap,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final playing = ctrl.current?.id == track.id;
    return ListTile(
      onTap: onTap,
      selected: playing,
      selectedColor: cs.primary,
      selectedTileColor: cs.primary.withAlpha(36),
      shape: playing
          ? Border(left: BorderSide(color: cs.primary, width: 4))
          : null,
      leading: Stack(
        alignment: Alignment.center,
        children: [
          TrackArt(track: track, size: 50),
          if (playing)
            Container(
              width: 50,
              height: 50,
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Center(
                child: MusicBars(
                  count: 3,
                  width: 20,
                  height: 18,
                  color: Colors.white,
                  animate: ctrl.player.playing,
                ),
              ),
            ),
        ],
      ),
      title: Text(
        track.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontWeight: playing ? FontWeight.bold : null),
      ),
      subtitle:
          Text(track.artist, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: trailing ?? trackMenu(context, track),
    );
  }
}

// ===========================================================================
// PESTAÑA: CANCIONES (con "Ordenar por" y más escuchadas)
// ===========================================================================
const _sortLabels = <String, List<String>>{
  'recent': ['Más recientes', 'Most recent'],
  'plays': ['Más reproducido', 'Most played'],
  'az': ['A a Z', 'A to Z'],
  'artist': ['Artista', 'Artist'],
  'duration': ['Duración más larga', 'Longest duration'],
};

String sortLabel(String k) => tr(_sortLabels[k]![0], _sortLabels[k]![1]);

class SongsTab extends StatelessWidget {
  const SongsTab({super.key});

  String _greeting() {
    final h = DateTime.now().hour;
    if (h < 12) return tr('Buenos días', 'Good morning');
    if (h < 19) return tr('Buenas tardes', 'Good afternoon');
    return tr('Buenas noches', 'Good evening');
  }

  Widget _notifBanner(BuildContext context) {
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.notifications_off_outlined),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    tr('Activa las notificaciones', 'Turn on notifications'),
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(tr(
                'Así verás los controles de música en la barra de estado y en la pantalla de bloqueo.',
                'So you can see the music controls in the status bar and on the lock screen.')),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: ctrl.hideNotifBanner,
                  child: Text(tr('Ahora no', 'Not now')),
                ),
                FilledButton(
                  onPressed: () async {
                    await ctrl.checkNotifications(ask: true);
                    if (!ctrl.notifOk) {
                      try {
                        await AppSettings.openAppSettings(
                            type: AppSettingsType.notification);
                      } catch (_) {}
                    }
                  },
                  child: Text(tr('Activar', 'Enable')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    final top = ctrl.tracks.where((t) => (ctrl.plays['${t.id}'] ?? 0) > 0).toList()
      ..sort((a, b) =>
          (ctrl.plays['${b.id}'] ?? 0).compareTo(ctrl.plays['${a.id}'] ?? 0));
    final favs = top.take(8).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!ctrl.notifOk && !ctrl.notifBannerHidden) _notifBanner(context),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text(_greeting(),
              style: Theme.of(context).textTheme.headlineSmall),
        ),
        if (favs.length >= 3) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
            child: Text(tr('Tus más escuchadas', 'Your most played'),
                style: Theme.of(context).textTheme.titleSmall),
          ),
          SizedBox(
            height: 140,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: favs.length,
              separatorBuilder: (_, __) => const SizedBox(width: 12),
              itemBuilder: (context, i) => GestureDetector(
                onTap: () => ctrl.playList(favs, i),
                child: SizedBox(
                  width: 104,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TrackArt(track: favs[i], size: 104, radius: 14),
                      const SizedBox(height: 4),
                      Text(favs[i].title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Row(
            children: [
              FilledButton.tonalIcon(
                onPressed: ctrl.playAllShuffled,
                icon: const Icon(Icons.shuffle),
                label: Text(tr('Aleatorio', 'Shuffle')),
              ),
              const Spacer(),
              PopupMenuButton<String>(
                onSelected: ctrl.setSort,
                itemBuilder: (_) => [
                  for (final k in _sortLabels.keys)
                    CheckedPopupMenuItem<String>(
                      value: k,
                      checked: ctrl.sortMode == k,
                      child: Text(sortLabel(k)),
                    ),
                ],
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Row(
                    children: [
                      const Icon(Icons.sort),
                      const SizedBox(width: 6),
                      Text(sortLabel(ctrl.sortMode)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ctrl,
      builder: (context, _) {
        if (ctrl.loading && ctrl.all.isEmpty) return const MusicLoader();
        if (!ctrl.hasPermission) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(tr('Necesito permiso para ver tu música',
                    'I need permission to see your music')),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: ctrl.loadSongs,
                  child: Text(tr('Dar permiso', 'Grant permission')),
                ),
              ],
            ),
          );
        }
        if (ctrl.tracks.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                tr('No encontré canciones. Descarga música y desliza hacia abajo para actualizar.',
                    'No songs found. Download music and pull down to refresh.'),
                textAlign: TextAlign.center,
              ),
            ),
          );
        }
        return RefreshIndicator(
          onRefresh: ctrl.loadSongs,
          child: ListView.builder(
            physics: const AlwaysScrollableScrollPhysics(),
            itemCount: ctrl.tracks.length + 1,
            itemBuilder: (context, i) {
              if (i == 0) return _header(context);
              return TrackTile(
                track: ctrl.tracks[i - 1],
                onTap: () => ctrl.playList(ctrl.tracks, i - 1),
              );
            },
          ),
        );
      },
    );
  }
}

// ===========================================================================
// PESTAÑAS: CARPETAS Y ARTISTAS (con miniaturas)
// ===========================================================================
class GroupTab extends StatelessWidget {
  final bool isFolder;
  const GroupTab({super.key, required this.isFolder});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ctrl,
      builder: (context, _) {
        final groups = <String, List<Track>>{};
        for (final t in ctrl.tracks) {
          groups.putIfAbsent(isFolder ? t.folder : t.artist, () => []).add(t);
        }
        final keys = groups.keys.toList()
          ..sort((a, b) => (isFolder ? lastSeg(a) : a)
              .toLowerCase()
              .compareTo((isFolder ? lastSeg(b) : b).toLowerCase()));
        if (keys.isEmpty) {
          return Center(child: Text(tr('Sin canciones', 'No songs')));
        }
        return ListView.builder(
          itemCount: keys.length,
          itemBuilder: (context, i) {
            final k = keys[i];
            final list = groups[k]!;
            final name = isFolder ? lastSeg(k) : k;
            final withArt = list.firstWhere((t) => t.msId != null,
                orElse: () => list.first);
            return ListTile(
              leading: TrackArt(
                  track: withArt, size: 50, radius: isFolder ? 8 : 25),
              title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text('${list.length} ${tr('canciones', 'songs')}'),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => TrackListPage(name, list)),
              ),
            );
          },
        );
      },
    );
  }
}

class TrackListPage extends StatelessWidget {
  final String title;
  final List<Track> list;
  const TrackListPage(this.title, this.list, {super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ctrl,
      builder: (context, _) {
        final visible = ctrl.tracks.map((t) => t.id).toSet();
        final items = list.where((t) => visible.contains(t.id)).toList();
        return Scaffold(
          appBar: AppBar(
            title: Text(title),
            actions: [
              IconButton(
                icon: const Icon(Icons.play_arrow),
                onPressed: items.isEmpty ? null : () => ctrl.playList(items, 0),
              ),
            ],
          ),
          body: ListView.builder(
            itemCount: items.length,
            itemBuilder: (context, i) => TrackTile(
              track: items[i],
              onTap: () => ctrl.playList(items, i),
            ),
          ),
        );
      },
    );
  }
}

// ===========================================================================
// PESTAÑA: PLAYLISTS
// ===========================================================================
class PlaylistsTab extends StatelessWidget {
  const PlaylistsTab({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ctrl,
      builder: (context, _) {
        final names = ctrl.playlists.keys.toList();
        return Column(
          children: [
            ListTile(
              leading: const Icon(Icons.add),
              title: Text(tr('Nueva lista', 'New playlist')),
              onTap: () async {
                final name = await askName(context);
                if (name != null && name.isNotEmpty) ctrl.createPlaylist(name);
              },
            ),
            Expanded(
              child: ListView.builder(
                itemCount: names.length,
                itemBuilder: (context, i) {
                  final n = names[i];
                  return ListTile(
                    leading: const Icon(Icons.queue_music),
                    title: Text(n),
                    subtitle: Text(
                        '${ctrl.playlists[n]!.length} ${tr('canciones', 'songs')}'),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => ctrl.deletePlaylist(n),
                    ),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => PlaylistPage(n)),
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

class PlaylistPage extends StatelessWidget {
  final String name;
  const PlaylistPage(this.name, {super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ctrl,
      builder: (context, _) {
        final byId = {for (final t in ctrl.tracks) t.id: t};
        final list = [
          for (final id in ctrl.playlists[name] ?? <int>[])
            if (byId[id] != null) byId[id]!,
        ];
        return Scaffold(
          appBar: AppBar(
            title: Text(name),
            actions: [
              IconButton(
                icon: const Icon(Icons.play_arrow),
                onPressed: list.isEmpty ? null : () => ctrl.playList(list, 0),
              ),
            ],
          ),
          body: list.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      tr('Lista vacía. Agrega canciones con los tres puntos (⋮).',
                          'Empty list. Add songs with the three dots (⋮).'),
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView.builder(
                  itemCount: list.length,
                  itemBuilder: (context, i) => TrackTile(
                    track: list[i],
                    onTap: () => ctrl.playList(list, i),
                    trailing: IconButton(
                      icon: const Icon(Icons.remove_circle_outline),
                      onPressed: () =>
                          ctrl.removeFromPlaylist(name, list[i].id),
                    ),
                  ),
                ),
        );
      },
    );
  }
}

// ===========================================================================
// PESTAÑA: VIDEOS
// ===========================================================================
class VideosTab extends StatefulWidget {
  const VideosTab({super.key});
  @override
  State<VideosTab> createState() => _VideosTabState();
}

class _VideosTabState extends State<VideosTab>
    with AutomaticKeepAliveClientMixin {
  List<AssetEntity>? _items;
  bool _denied = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final ps = await PhotoManager.requestPermissionExtend();
    if (!ps.hasAccess) {
      if (mounted) setState(() => _denied = true);
      return;
    }
    final paths = await PhotoManager.getAssetPathList(
      type: RequestType.video,
      onlyAll: true,
    );
    final items = paths.isEmpty
        ? <AssetEntity>[]
        : await paths.first.getAssetListPaged(page: 0, size: 300);
    if (mounted) {
      setState(() {
        _items = items;
        _denied = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_denied) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(tr('Necesito permiso para ver tus videos',
                'I need permission to see your videos')),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _load,
              child: Text(tr('Dar permiso', 'Grant permission')),
            ),
          ],
        ),
      );
    }
    if (_items == null) return const MusicLoader();
    if (_items!.isEmpty) {
      return Center(child: Text(tr('No encontré videos', 'No videos found')));
    }
    return GridView.builder(
      padding: const EdgeInsets.all(8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 16 / 10,
      ),
      itemCount: _items!.length,
      itemBuilder: (context, i) {
        final a = _items![i];
        return GestureDetector(
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => VideoPage(a)),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Stack(
              fit: StackFit.expand,
              children: [
                FutureBuilder<Uint8List?>(
                  future: a.thumbnailDataWithSize(const ThumbnailSize(400, 400)),
                  builder: (context, s) => s.data == null
                      ? Container(color: Colors.white12)
                      : Image.memory(s.data!,
                          fit: BoxFit.cover,
                          filterQuality: FilterQuality.high),
                ),
                Positioned(
                  right: 6,
                  bottom: 6,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    color: Colors.black54,
                    child: Text(fmt(a.videoDuration),
                        style: const TextStyle(
                            fontSize: 12, color: Colors.white)),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class VideoPage extends StatefulWidget {
  final AssetEntity asset;
  const VideoPage(this.asset, {super.key});
  @override
  State<VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<VideoPage> {
  VideoPlayerController? _c;
  String? _err;

  @override
  void initState() {
    super.initState();
    ctrl.setVideoActive(true);
    ctrl.player.pause();
    _init();
  }

  Future<void> _init() async {
    try {
      final f = await widget.asset.file;
      if (f == null) throw 'No file';
      final c = VideoPlayerController.file(f);
      await c.initialize();
      await c.play();
      if (!mounted) {
        c.dispose();
        return;
      }
      c.addListener(() {
        if (mounted) setState(() {});
      });
      setState(() => _c = c);
    } catch (e) {
      if (mounted) setState(() => _err = '$e');
    }
  }

  @override
  void dispose() {
    _c?.dispose();
    ctrl.setVideoActive(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text(widget.asset.title ?? 'Video'),
      ),
      body: _err != null
          ? Center(child: Text(_err!))
          : c == null
              ? const MusicLoader()
              : Column(
                  children: [
                    Expanded(
                      child: Center(
                        child: AspectRatio(
                          aspectRatio: c.value.aspectRatio,
                          child: VideoPlayer(c),
                        ),
                      ),
                    ),
                    VideoProgressIndicator(c, allowScrubbing: true),
                    IconButton(
                      iconSize: 48,
                      icon: Icon(
                          c.value.isPlaying ? Icons.pause : Icons.play_arrow),
                      onPressed: () =>
                          c.value.isPlaying ? c.pause() : c.play(),
                    ),
                    const SizedBox(height: 16),
                  ],
                ),
    );
  }
}

// ===========================================================================
// MINI REPRODUCTOR (con color de la carátula y barra de progreso)
// ===========================================================================
class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<int?>(
      stream: ctrl.player.currentIndexStream,
      builder: (context, snap) {
        final s = ctrl.current;
        if (s == null) return const SizedBox.shrink();
        final cs = Theme.of(context).colorScheme;
        final g = ctrl.glow;
        final tint = g != null
            ? g.withAlpha((ctrl.glowAlpha * 0.4).round())
            : Colors.transparent;
        return Material(
          color: Color.alphaBlend(tint, cs.surfaceContainer),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                StreamBuilder<Duration>(
                  stream: ctrl.player.positionStream,
                  builder: (context, ps) {
                    final dur = ctrl.player.duration?.inMilliseconds ?? 0;
                    final pos = ps.data?.inMilliseconds ?? 0;
                    return LinearProgressIndicator(
                      minHeight: 2,
                      value: dur > 0 ? (pos / dur).clamp(0.0, 1.0) : 0,
                      backgroundColor: Colors.transparent,
                    );
                  },
                ),
                ListTile(
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const NowPlayingPage()),
                  ),
                  leading: TrackArt(track: s, size: 44),
                  title: Text(s.title,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(s.artist,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: const PlayPauseButton(),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ===========================================================================
// REPRODUCTOR GRANDE (carrusel de carátulas, colores vivos, letras)
// ===========================================================================
class NowPlayingPage extends StatefulWidget {
  const NowPlayingPage({super.key});
  @override
  State<NowPlayingPage> createState() => _NowPlayingPageState();
}

class _NowPlayingPageState extends State<NowPlayingPage> {
  bool _lyrics = false;
  final PageController _pc = PageController(viewportFraction: 0.82);
  bool _programmatic = false;
  bool _first = true;

  @override
  void dispose() {
    _pc.dispose();
    super.dispose();
  }

  /// Mueve el carrusel a la canción que suena (si se cambió con los botones,
  /// la notificación o los auriculares).
  void _syncTo(int pos) {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || !_pc.hasClients || !_pc.position.hasPixels) return;
      final cur = (_pc.page ?? pos.toDouble()).round();
      if (cur == pos) {
        _first = false;
        return;
      }
      _programmatic = true;
      try {
        if (_first || (cur - pos).abs() > 3) {
          _pc.jumpToPage(pos);
        } else {
          await _pc.animateToPage(
            pos,
            duration: const Duration(milliseconds: 380),
            curve: Curves.easeOutCubic,
          );
        }
      } catch (_) {
      } finally {
        _programmatic = false;
        _first = false;
      }
    });
  }

  Widget _carousel(Color glow) {
    final p = ctrl.player;
    return StreamBuilder<SequenceState?>(
      stream: p.sequenceStateStream,
      builder: (context, snap) {
        final n = ctrl.queue.length;
        if (n == 0) return const SizedBox.shrink();
        final st = snap.data;
        var order = List<int>.generate(n, (i) => i);
        if (st != null &&
            st.shuffleModeEnabled &&
            st.shuffleIndices.length == n) {
          order = st.shuffleIndices;
        }
        final cur = p.currentIndex ?? 0;
        final pos = max(0, order.indexOf(cur));
        _syncTo(pos);
        return LayoutBuilder(
          builder: (context, box) {
            final side = max(120.0, min(box.maxWidth * 0.82 - 20, box.maxHeight - 16));
            return PageView.builder(
              controller: _pc,
              itemCount: n,
              onPageChanged: (i) {
                if (_programmatic || i >= order.length) return;
                final qi = order[i];
                if (qi != p.currentIndex) p.seek(Duration.zero, index: qi);
              },
              itemBuilder: (context, i) {
                final t = ctrl.queue[order[i]];
                return AnimatedBuilder(
                  animation: _pc,
                  builder: (context, child) {
                    var page = pos.toDouble();
                    if (_pc.hasClients && _pc.position.hasPixels) {
                      page = _pc.page ?? page;
                    }
                    final d = (page - i).abs().clamp(0.0, 1.0).toDouble();
                    return Transform.scale(
                      scale: 1 - 0.16 * d,
                      child: Opacity(opacity: 1 - 0.5 * d, child: child),
                    );
                  },
                  child: Center(
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(22),
                        boxShadow: [
                          BoxShadow(
                            color: glow.withAlpha(120),
                            blurRadius: 36,
                            spreadRadius: 1,
                          ),
                        ],
                      ),
                      child: TrackArt(track: t, size: side, radius: 22),
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = ctrl.player;
    return ListenableBuilder(
      listenable: ctrl,
      builder: (context, _) {
        final s = ctrl.current;
        final cs = Theme.of(context).colorScheme;
        final glow = ctrl.glow ?? cs.primary;
        if (s == null) {
          return Scaffold(
            appBar: AppBar(),
            body: Center(
                child: Text(tr('No hay nada sonando', 'Nothing playing'))),
          );
        }
        final a = ctrl.glowAlpha;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 700),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              stops: const [0.0, 0.55, 1.0],
              colors: [
                glow.withAlpha(a),
                glow.withAlpha((a * 0.35).round()),
                cs.surface,
              ],
            ),
          ),
          child: Scaffold(
            backgroundColor: Colors.transparent,
            appBar: AppBar(
              backgroundColor: Colors.transparent,
              surfaceTintColor: Colors.transparent,
              title: Text(tr('Reproduciendo', 'Now playing')),
              actions: [
                IconButton(
                  icon: Icon(_lyrics ? Icons.album : Icons.lyrics_outlined),
                  tooltip: tr('Letra', 'Lyrics'),
                  onPressed: () => setState(() => _lyrics = !_lyrics),
                ),
                IconButton(
                  icon: const Icon(Icons.equalizer),
                  tooltip: tr('Ecualizador', 'Equalizer'),
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const EqualizerPage()),
                  ),
                ),
                trackMenu(context, s),
              ],
            ),
            body: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Column(
                children: [
                  Expanded(
                    child: _lyrics ? LyricsView(s) : _carousel(glow),
                  ),
                  const SizedBox(height: 12),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 300),
                    transitionBuilder: (child, anim) => FadeTransition(
                      opacity: anim,
                      child: SlideTransition(
                        position: Tween<Offset>(
                          begin: const Offset(0.15, 0),
                          end: Offset.zero,
                        ).animate(anim),
                        child: child,
                      ),
                    ),
                    child: Column(
                      key: ValueKey(s.id),
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          s.title,
                          style: Theme.of(context).textTheme.titleLarge,
                          maxLines: 2,
                          textAlign: TextAlign.center,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        Text(s.artist),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  StreamBuilder<Duration>(
                    stream: p.positionStream,
                    builder: (context, snap) {
                      final pos = snap.data ?? Duration.zero;
                      final dur = p.duration ?? Duration.zero;
                      final mx = dur.inMilliseconds > 0
                          ? dur.inMilliseconds.toDouble()
                          : 1.0;
                      final val = pos.inMilliseconds
                          .toDouble()
                          .clamp(0.0, mx)
                          .toDouble();
                      return Column(
                        children: [
                          Slider(
                            value: val,
                            max: mx,
                            onChanged: (v) =>
                                p.seek(Duration(milliseconds: v.round())),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [Text(fmt(pos)), Text(fmt(dur))],
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      StreamBuilder<bool>(
                        stream: p.shuffleModeEnabledStream,
                        builder: (context, snap) => IconButton(
                          icon: Icon(
                            Icons.shuffle,
                            color: (snap.data ?? false) ? cs.primary : null,
                          ),
                          onPressed: ctrl.toggleShuffle,
                        ),
                      ),
                      IconButton(
                        iconSize: 40,
                        icon: const Icon(Icons.skip_previous),
                        onPressed: p.seekToPrevious,
                      ),
                      const PlayPauseButton(size: 64),
                      IconButton(
                        iconSize: 40,
                        icon: const Icon(Icons.skip_next),
                        onPressed: p.seekToNext,
                      ),
                      StreamBuilder<LoopMode>(
                        stream: p.loopModeStream,
                        builder: (context, snap) {
                          final m = snap.data ?? LoopMode.off;
                          return IconButton(
                            icon: Icon(
                              m == LoopMode.one
                                  ? Icons.repeat_one
                                  : Icons.repeat,
                              color: m == LoopMode.off ? null : cs.primary,
                            ),
                            onPressed: ctrl.cycleRepeat,
                          );
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

// ===========================================================================
// LETRAS SINCRONIZADAS
// ===========================================================================
class LyricsView extends StatefulWidget {
  final Track track;
  const LyricsView(this.track, {super.key});
  @override
  State<LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends State<LyricsView> {
  Future<Lyrics?>? _f;
  bool _searching = false;
  final _sc = ScrollController();
  int _last = -1;

  @override
  void initState() {
    super.initState();
    _f = ctrl.loadLyrics(widget.track);
  }

  @override
  void didUpdateWidget(LyricsView old) {
    super.didUpdateWidget(old);
    if (old.track.id != widget.track.id) {
      _last = -1;
      _f = ctrl.loadLyrics(widget.track);
    }
  }

  @override
  void dispose() {
    _sc.dispose();
    super.dispose();
  }

  Future<void> _online() async {
    setState(() => _searching = true);
    final l = await ctrl.loadLyrics(widget.track, forceOnline: true);
    if (!mounted) return;
    setState(() {
      _searching = false;
      _f = Future.value(l);
    });
    if (l == null) {
      snack(context, tr('No encontré letra para esta canción.',
          'No lyrics found for this song.'));
    }
  }

  Future<void> _paste() async {
    final t = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Pegar letra', 'Paste lyrics')),
        content: TextField(
          controller: t,
          maxLines: 10,
          decoration: InputDecoration(
            hintText: tr('Texto simple o formato .lrc con tiempos [00:12.50]',
                'Plain text or .lrc format with times [00:12.50]'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('Cancelar', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('Guardar', 'Save')),
          ),
        ],
      ),
    );
    if (ok == true && t.text.trim().isNotEmpty) {
      await ctrl.saveLyrics(widget.track, t.text);
      if (mounted) setState(() => _f = ctrl.loadLyrics(widget.track));
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Lyrics?>(
      future: _f,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const MusicLoader();
        }
        final l = snap.data;
        if (l == null) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(tr('No hay letra guardada para esta canción.',
                    'No lyrics saved for this song.')),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: _searching ? null : _online,
                  icon: _searching
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.cloud_download),
                  label: Text(tr('Buscar en internet', 'Search online')),
                ),
                TextButton(
                  onPressed: _paste,
                  child: Text(tr('Pegar letra manualmente', 'Paste lyrics')),
                ),
              ],
            ),
          );
        }
        if (!l.synced) {
          return ListView(
            children: [
              for (final line in l.lines)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Text(line.text,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 18)),
                ),
            ],
          );
        }
        return StreamBuilder<Duration>(
          stream: ctrl.player.positionStream,
          builder: (context, ps) {
            final pos = ps.data ?? Duration.zero;
            var idx = 0;
            for (var i = 0; i < l.lines.length; i++) {
              if (l.lines[i].time <= pos) idx = i;
            }
            if (idx != _last) {
              _last = idx;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (_sc.hasClients) {
                  final target = max(0.0, (idx - 2) * 44.0);
                  _sc.animateTo(
                    min(target, _sc.position.maxScrollExtent),
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeOut,
                  );
                }
              });
            }
            return ListView.builder(
              controller: _sc,
              itemExtent: 44,
              itemCount: l.lines.length,
              itemBuilder: (context, i) => Center(
                child: Text(
                  l.lines[i].text,
                  maxLines: 2,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: i == idx ? 20 : 16,
                    fontWeight: i == idx ? FontWeight.bold : FontWeight.normal,
                    color: i == idx
                        ? Theme.of(context).colorScheme.primary
                        : null,
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

// ===========================================================================
// ECUALIZADOR PROFESIONAL
// ===========================================================================
class _CurvePainter extends CustomPainter {
  final List<double> g;
  final double minDb;
  final double maxDb;
  final Color color;
  _CurvePainter(this.g, this.minDb, this.maxDb, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    if (g.isEmpty) return;
    final n = g.length;
    final range = (maxDb - minDb) == 0 ? 1.0 : (maxDb - minDb);
    double yOf(double v) => size.height * (1 - (v - minDb) / range);
    final zero = yOf(0);
    canvas.drawLine(
      Offset(0, zero),
      Offset(size.width, zero),
      Paint()
        ..color = color.withAlpha(60)
        ..strokeWidth = 1,
    );
    final pts = [
      for (var i = 0; i < n; i++)
        Offset(size.width * (i + 0.5) / n, yOf(g[i])),
    ];
    final path = Path()..moveTo(0, pts.first.dy);
    path.lineTo(pts.first.dx, pts.first.dy);
    for (var i = 0; i < n - 1; i++) {
      final mid = (pts[i].dx + pts[i + 1].dx) / 2;
      path.cubicTo(mid, pts[i].dy, mid, pts[i + 1].dy, pts[i + 1].dx,
          pts[i + 1].dy);
    }
    path.lineTo(size.width, pts.last.dy);
    final fill = Path.from(path)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withAlpha(110), color.withAlpha(8)],
        ).createShader(Offset.zero & size),
    );
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..color = color,
    );
    for (final p in pts) {
      canvas.drawCircle(p, 4.5, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

class EqualizerPage extends StatefulWidget {
  const EqualizerPage({super.key});
  @override
  State<EqualizerPage> createState() => _EqualizerPageState();
}

class _EqualizerPageState extends State<EqualizerPage> {
  AndroidEqualizerParameters? _params;
  List<double> _gains = [];
  double _loud = 0;
  String _preset = '';
  bool _failed = false;

  static const _presets = <String, List<double>>{
    'normal': [0, 0, 0, 0, 0],
    'bass': [7, 5, 1, 0, 0],
    'rock': [5, 3, -2, 3, 5],
    'pop': [-1, 2, 4, 2, -1],
    'jazz': [3, 1, -2, 2, 4],
    'classic': [3, 2, -1, 2, 3],
    'vocal': [-2, 0, 4, 3, 1],
    'electro': [6, 4, 0, 3, 5],
  };

  String _presetName(String k) {
    switch (k) {
      case 'normal':
        return 'Normal';
      case 'bass':
        return tr('Más graves', 'Bass boost');
      case 'rock':
        return 'Rock';
      case 'pop':
        return 'Pop';
      case 'jazz':
        return 'Jazz';
      case 'classic':
        return tr('Clásica', 'Classical');
      case 'vocal':
        return tr('Voces', 'Vocal');
      default:
        return tr('Electrónica', 'Electronic');
    }
  }

  @override
  void initState() {
    super.initState();
    if (ctrl.queue.isNotEmpty) _load();
  }

  Future<void> _load() async {
    try {
      final p = await ctrl.equalizer.parameters
          .timeout(const Duration(seconds: 8));
      var loud = 0.0;
      try {
        final m =
            jsonDecode(ctrl.prefs.getString('eq') ?? '{}') as Map<String, dynamic>;
        loud = (m['lg'] as num?)?.toDouble() ?? 0;
      } catch (_) {}
      await ctrl.equalizer.setEnabled(ctrl.eqOn);
      if (!mounted) return;
      setState(() {
        _params = p;
        _gains = p.bands.map((b) => b.gain).toList();
        _loud = loud;
      });
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  void _save() {
    ctrl.saveEq(_gains, _loud);
    setState(() {});
  }

  void _setBand(int i, double v) {
    _gains[i] = v;
    _params!.bands[i].setGain(v);
    _preset = '';
    if (!ctrl.eqOn) ctrl.setEqEnabled(true);
    _save();
  }

  void _applyPreset(String key) {
    final v = _presets[key]!;
    final n = _params!.bands.length;
    for (var i = 0; i < n; i++) {
      final idx = n == 1 ? 0 : (i * (v.length - 1) / (n - 1)).round();
      final g = v[idx]
          .clamp(_params!.minDecibels, _params!.maxDecibels)
          .toDouble();
      _gains[i] = g;
      _params!.bands[i].setGain(g);
    }
    _preset = key;
    if (!ctrl.eqOn) ctrl.setEqEnabled(true);
    _save();
  }

  String _hz(double f) =>
      f >= 1000 ? '${(f / 1000).toStringAsFixed(f >= 10000 ? 0 : 1)}k' : '${f.round()}';

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final p = _params;
    Widget body;
    if (ctrl.queue.isEmpty) {
      body = Center(
        child: Text(tr('Primero pon una canción y vuelve aquí.',
            'Play a song first and come back here.')),
      );
    } else if (_failed) {
      body = Center(
        child: Text(tr('Este teléfono no permite ecualizador.',
            'This phone does not support an equalizer.')),
      );
    } else if (p == null) {
      body = const MusicLoader();
    } else {
      body = ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: SwitchListTile(
              secondary: const Icon(Icons.equalizer),
              title: Text(tr('Ecualizador', 'Equalizer'),
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text(ctrl.eqOn
                  ? tr('Activado', 'On')
                  : tr('Apagado', 'Off')),
              value: ctrl.eqOn,
              onChanged: (v) {
                ctrl.setEqEnabled(v);
                setState(() {});
              },
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 40,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final k in _presets.keys)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(_presetName(k)),
                      selected: _preset == k,
                      onSelected: (_) => _applyPreset(k),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 16, 12, 8),
              child: SizedBox(
                height: 110,
                child: CustomPaint(
                  painter: _CurvePainter(
                      _gains, p.minDecibels, p.maxDecibels, cs.primary),
                  size: Size.infinite,
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
              child: Row(
                children: [
                  for (var i = 0; i < p.bands.length; i++)
                    Expanded(
                      child: Column(
                        children: [
                          Text(
                            '${_gains[i] > 0 ? '+' : ''}${_gains[i].toStringAsFixed(0)}',
                            style: TextStyle(
                                color: cs.primary,
                                fontWeight: FontWeight.bold),
                          ),
                          SizedBox(
                            height: 210,
                            child: RotatedBox(
                              quarterTurns: 3,
                              child: Slider(
                                min: p.minDecibels,
                                max: p.maxDecibels,
                                value: _gains[i]
                                    .clamp(p.minDecibels, p.maxDecibels)
                                    .toDouble(),
                                onChanged: (v) => _setBand(i, v),
                              ),
                            ),
                          ),
                          Text(_hz(p.bands[i].centerFrequency),
                              style: const TextStyle(fontSize: 12)),
                          const Text('Hz', style: TextStyle(fontSize: 10)),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.volume_up),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(tr('Refuerzo de volumen', 'Volume boost'),
                            style:
                                const TextStyle(fontWeight: FontWeight.bold)),
                      ),
                      Text('+${_loud.toStringAsFixed(1)} dB'),
                    ],
                  ),
                  Slider(
                    min: 0,
                    max: 8,
                    divisions: 16,
                    value: _loud,
                    onChanged: (v) => setState(() => _loud = v),
                    onChangeEnd: (v) async {
                      try {
                        await ctrl.loudness.setTargetGain(v);
                        await ctrl.loudness.setEnabled(v > 0);
                      } catch (_) {}
                      _save();
                    },
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Center(
            child: TextButton.icon(
              onPressed: () async {
                for (var i = 0; i < p.bands.length; i++) {
                  _gains[i] = 0;
                  p.bands[i].setGain(0);
                }
                _loud = 0;
                try {
                  await ctrl.loudness.setTargetGain(0);
                  await ctrl.loudness.setEnabled(false);
                } catch (_) {}
                _preset = 'normal';
                _save();
              },
              icon: const Icon(Icons.restart_alt),
              label: Text(tr('Restablecer todo', 'Reset all')),
            ),
          ),
        ],
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(tr('Ecualizador', 'Equalizer'))),
      body: body,
    );
  }
}

// ===========================================================================
// VISUALIZADOR (animación decorativa que se mueve con la música)
// ===========================================================================
class VisualizerPage extends StatefulWidget {
  const VisualizerPage({super.key});
  @override
  State<VisualizerPage> createState() => _VisualizerPageState();
}

class _VisualizerPageState extends State<VisualizerPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(seconds: 2))
        ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return Scaffold(
      appBar: AppBar(title: Text(tr('Visualizador', 'Visualizer'))),
      body: StreamBuilder<bool>(
        stream: ctrl.player.playingStream,
        builder: (context, snap) {
          final playing = snap.data ?? false;
          final t = ctrl.current;
          return Column(
            children: [
              const SizedBox(height: 16),
              if (t != null) TrackArt(track: t, size: 120, radius: 16),
              const SizedBox(height: 8),
              if (t != null)
                Text(t.title, style: Theme.of(context).textTheme.titleMedium),
              Expanded(
                child: AnimatedBuilder(
                  animation: _c,
                  builder: (context, _) => Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      for (int i = 0; i < 24; i++)
                        Container(
                          width: 8,
                          height: playing
                              ? 12 +
                                  180 *
                                      (0.5 +
                                          0.5 *
                                              sin(_c.value *
                                                      2 *
                                                      pi *
                                                      (1 + i % 3) +
                                                  i * 0.7))
                              : 12,
                          decoration: BoxDecoration(
                            color: color,
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const PlayPauseButton(size: 64),
              const SizedBox(height: 24),
            ],
          );
        },
      ),
    );
  }
}

// ===========================================================================
// MODO GIRATORIO: DISCO DE VINILO (teléfono en horizontal)
// ===========================================================================
class _GroovePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final r = size.width / 2;
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = Colors.white.withAlpha(28);
    for (double k = 0.5; k < 0.98; k += 0.05) {
      canvas.drawCircle(center, r * k, p);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class VinylView extends StatefulWidget {
  const VinylView({super.key});
  @override
  State<VinylView> createState() => _VinylViewState();
}

class _VinylViewState extends State<VinylView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(seconds: 6));
  StreamSubscription<bool>? _sub;

  @override
  void initState() {
    super.initState();
    if (ctrl.player.playing) _c.repeat();
    _sub = ctrl.player.playingStream.listen((p) {
      if (p) {
        _c.repeat();
      } else {
        _c.stop();
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _c.dispose();
    super.dispose();
  }

  Widget _disc(double d, Track t) {
    return Container(
      width: d,
      height: d,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [Color(0xFF2B2B2B), Color(0xFF0A0A0A)],
        ),
        boxShadow: [BoxShadow(blurRadius: 20, color: Colors.black54)],
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          CustomPaint(size: Size(d, d), painter: _GroovePainter()),
          TrackArt(track: t, size: d * 0.4, radius: d * 0.2),
          Container(
            width: d * 0.05,
            height: d * 0.05,
            decoration: const BoxDecoration(
              color: Colors.black,
              shape: BoxShape.circle,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = ctrl.current;
    if (t == null) return const SizedBox.shrink();
    final p = ctrl.player;
    final glow = ctrl.glow ?? const Color(0xFF7C3AED);
    return Scaffold(
      backgroundColor: Colors.black,
      body: Container(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: const Alignment(-0.5, 0),
            radius: 1.1,
            colors: [glow.withAlpha(120), Colors.black],
          ),
        ),
        child: SafeArea(
          child: Row(
            children: [
              Expanded(
                child: LayoutBuilder(
                  builder: (context, box) {
                    final d = min(box.maxWidth, box.maxHeight) * 0.9;
                    return Center(
                      child: RotationTransition(
                        turns: _c,
                        child: _disc(d, t),
                      ),
                    );
                  },
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        t.title,
                        maxLines: 2,
                        textAlign: TextAlign.center,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(t.artist,
                          style: const TextStyle(color: Colors.white70)),
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          IconButton(
                            iconSize: 40,
                            color: Colors.white,
                            icon: const Icon(Icons.skip_previous),
                            onPressed: p.seekToPrevious,
                          ),
                          IconTheme(
                            data: const IconThemeData(color: Colors.white),
                            child: const PlayPauseButton(size: 64),
                          ),
                          IconButton(
                            iconSize: 40,
                            color: Colors.white,
                            icon: const Icon(Icons.skip_next),
                            onPressed: p.seekToNext,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ===========================================================================
// BUSCADOR Y SITIOS
// ===========================================================================
class SearchPage extends StatefulWidget {
  const SearchPage({super.key});
  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _t = TextEditingController();
  String _q = '';

  void _openWeb(String title, String url) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => WebPage(title, url)),
    );
  }

  Future<void> _addSite() async {
    final name = TextEditingController();
    final url = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Agregar sitio', 'Add site')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              decoration: InputDecoration(labelText: tr('Nombre', 'Name')),
            ),
            TextField(
              controller: url,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'URL',
                hintText: 'https://...',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('Cancelar', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('Guardar', 'Save')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    var u = url.text.trim();
    if (u.isEmpty) return;
    if (!u.startsWith('http')) u = 'https://$u';
    final uri = Uri.tryParse(u);
    if (uri == null || uri.host.isEmpty) {
      if (mounted) snack(context, tr('Esa dirección no es válida.', 'That address is not valid.'));
      return;
    }
    final n = name.text.trim();
    ctrl.addSite(n.isEmpty ? uri.host : n, u);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ctrl,
      builder: (context, _) {
        final q = _q.trim().toLowerCase();
        final results = q.isEmpty
            ? <Track>[]
            : ctrl.tracks
                .where((t) =>
                    t.title.toLowerCase().contains(q) ||
                    t.artist.toLowerCase().contains(q))
                .toList();
        final enc = Uri.encodeQueryComponent(_q.trim());
        return Scaffold(
          appBar: AppBar(
            title: TextField(
              controller: _t,
              decoration: InputDecoration(
                hintText:
                    tr('Buscar canciones o sitios', 'Search songs or sites'),
                border: InputBorder.none,
              ),
              onChanged: (v) => setState(() => _q = v),
            ),
          ),
          body: ListView(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Text(tr('Sitios', 'Sites'),
                    style: Theme.of(context).textTheme.titleMedium),
              ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ActionChip(
                      avatar: const Icon(Icons.smart_display, size: 18),
                      label: const Text('YouTube'),
                      onPressed: () => _openWeb(
                        'YouTube',
                        enc.isEmpty
                            ? 'https://m.youtube.com'
                            : 'https://m.youtube.com/results?search_query=$enc',
                      ),
                    ),
                    ActionChip(
                      avatar: const Icon(Icons.camera_alt, size: 18),
                      label: const Text('Instagram'),
                      onPressed: () =>
                          _openWeb('Instagram', 'https://www.instagram.com'),
                    ),
                    ActionChip(
                      avatar: const Icon(Icons.facebook, size: 18),
                      label: const Text('Facebook'),
                      onPressed: () =>
                          _openWeb('Facebook', 'https://m.facebook.com'),
                    ),
                    ActionChip(
                      avatar: const Icon(Icons.cloud, size: 18),
                      label: const Text('SoundCloud'),
                      onPressed: () => _openWeb(
                        'SoundCloud',
                        enc.isEmpty
                            ? 'https://m.soundcloud.com'
                            : 'https://m.soundcloud.com/search?q=$enc',
                      ),
                    ),
                    for (var i = 0; i < ctrl.sites.length; i++)
                      InputChip(
                        avatar: const Icon(Icons.language, size: 18),
                        label: Text(ctrl.sites[i]['n'] ?? ''),
                        onPressed: () => _openWeb(
                            ctrl.sites[i]['n'] ?? '', ctrl.sites[i]['u'] ?? ''),
                        onDeleted: () => ctrl.removeSite(i),
                      ),
                    ActionChip(
                      avatar: const Icon(Icons.add, size: 18),
                      label: Text(tr('Agregar sitio', 'Add site')),
                      onPressed: _addSite,
                    ),
                  ],
                ),
              ),
              if (q.isNotEmpty)
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Text(tr('En tu música', 'In your music'),
                      style: Theme.of(context).textTheme.titleMedium),
                ),
              for (int i = 0; i < results.length; i++)
                TrackTile(
                  track: results[i],
                  onTap: () => ctrl.playList(results, i),
                ),
              if (q.isNotEmpty && results.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(tr('Sin resultados en tu música.',
                      'No results in your music.')),
                ),
            ],
          ),
        );
      },
    );
  }
}

class WebPage extends StatefulWidget {
  final String title;
  final String url;
  const WebPage(this.title, this.url, {super.key});
  @override
  State<WebPage> createState() => _WebPageState();
}

class _WebPageState extends State<WebPage> {
  late final WebViewController _c;
  int _progress = 0;

  @override
  void initState() {
    super.initState();
    _c = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      ))
      ..loadRequest(Uri.parse(widget.url));
  }

  Future<void> _openExternal() async {
    final u = await _c.currentUrl() ?? widget.url;
    try {
      await launchUrl(Uri.parse(u), mode: LaunchMode.externalApplication);
    } catch (_) {
      if (mounted) {
        snack(context, tr('No pude abrir el navegador.', 'Could not open the browser.'));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        if (await _c.canGoBack()) {
          await _c.goBack();
        } else if (context.mounted) {
          Navigator.pop(context);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.title),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: () => _c.reload(),
            ),
            IconButton(
              icon: const Icon(Icons.open_in_browser),
              tooltip: tr('Abrir en el navegador', 'Open in browser'),
              onPressed: _openExternal,
            ),
          ],
          bottom: _progress < 100
              ? PreferredSize(
                  preferredSize: const Size.fromHeight(2),
                  child: LinearProgressIndicator(
                      value: _progress / 100, minHeight: 2),
                )
              : null,
        ),
        body: WebViewWidget(controller: _c),
      ),
    );
  }
}

// ===========================================================================
// AJUSTES
// ===========================================================================
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  Widget _section(BuildContext context, String t) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
        child: Text(t,
            style: TextStyle(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.bold,
            )),
      );

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ctrl,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(title: Text(tr('Ajustes', 'Settings'))),
          body: ListView(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    const PlayLogo(size: 56),
                    const SizedBox(width: 14),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Play Music',
                            style: TextStyle(
                                fontSize: 20, fontWeight: FontWeight.bold)),
                        Text(tr('Tu música. Sin anuncios.',
                            'Your music. No ads.')),
                      ],
                    ),
                  ],
                ),
              ),
              _section(context, tr('Reproducción', 'Playback')),
              SwitchListTile(
                title: Text(tr('Recordar aleatorio y repetir',
                    'Remember shuffle and repeat')),
                value: ctrl.rememberModes,
                onChanged: ctrl.setRemember,
              ),
              SwitchListTile(
                title: Text(tr('Disco de vinilo al girar la pantalla',
                    'Vinyl disc when rotating the screen')),
                value: ctrl.vinylOnRotate,
                onChanged: ctrl.setVinyl,
              ),
              ListTile(
                title: Text(tr('Ignorar canciones cortas', 'Ignore short songs')),
                trailing: DropdownButton<int>(
                  value: ctrl.minSeconds,
                  items: [
                    for (final s in [0, 15, 30, 60])
                      DropdownMenuItem(
                        value: s,
                        child: Text(s == 0 ? tr('No', 'No') : '$s s'),
                      ),
                  ],
                  onChanged: (v) {
                    if (v != null) ctrl.setMinSeconds(v);
                  },
                ),
              ),
              ListTile(
                title: Text(tr('Velocidad de reproducción', 'Playback speed')),
                trailing: Text('${ctrl.speed.toStringAsFixed(2)}x'),
                onTap: () => showSpeedDialog(context),
              ),
              ListTile(
                title: Text(tr('Ecualizador', 'Equalizer')),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const EqualizerPage()),
                ),
              ),
              _section(context, tr('Temporizador para dormir', 'Sleep timer')),
              ListTile(
                title: Text(tr('Temporizador para dormir', 'Sleep timer')),
                subtitle: Text(ctrl.sleepEnd == null
                    ? tr('Apagado', 'Off')
                    : '${tr('Se detiene a las', 'Stops at')} ${TimeOfDay.fromDateTime(ctrl.sleepEnd!).format(context)}'),
                onTap: () => showSleepDialog(context),
              ),
              _section(context, tr('Apariencia', 'Appearance')),
              SwitchListTile(
                title: Text(tr('Colores según la carátula',
                    'Colors from the album art')),
                subtitle: Text(tr('La app cambia de color con cada canción',
                    'The app changes color with each song')),
                value: ctrl.dynamicTheme,
                onChanged: ctrl.setDynamic,
              ),
              if (ctrl.dynamicTheme)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(tr('Intensidad del color', 'Color intensity')),
                          const Spacer(),
                          Text('${(ctrl.dynIntensity * 100).round()}%'),
                        ],
                      ),
                      Slider(
                        value: ctrl.dynIntensity,
                        onChanged: ctrl.setIntensity,
                      ),
                    ],
                  ),
                ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<String>(
                    segments: [
                      ButtonSegment(
                          value: 'dark', label: Text(tr('Oscuro', 'Dark'))),
                      ButtonSegment(
                          value: 'light', label: Text(tr('Claro', 'Light'))),
                      ButtonSegment(
                          value: 'system', label: Text(tr('Sistema', 'System'))),
                    ],
                    selected: {ctrl.themeMode},
                    onSelectionChanged: (s) => ctrl.setTheme(s.first),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Wrap(
                  spacing: 12,
                  children: [
                    for (int i = 0; i < accents.length; i++)
                      GestureDetector(
                        onTap: () => ctrl.setAccent(i),
                        child: CircleAvatar(
                          radius: 16,
                          backgroundColor: accents[i],
                          child: ctrl.accent == i
                              ? const Icon(Icons.check,
                                  size: 18, color: Colors.white)
                              : null,
                        ),
                      ),
                  ],
                ),
              ),
              ListTile(
                leading: const Icon(Icons.wallpaper),
                title: Text(tr('Elegir fondo de la galería',
                    'Choose background from gallery')),
                onTap: ctrl.pickBackground,
              ),
              if (ctrl.bgPath != null) ...[
                ListTile(
                  leading: const Icon(Icons.hide_image),
                  title: Text(tr('Quitar fondo', 'Remove background')),
                  onTap: ctrl.clearBackground,
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(tr('Oscurecer el fondo', 'Darken background')),
                          const Spacer(),
                          Text('${ctrl.bgDim}%'),
                        ],
                      ),
                      Slider(
                        value: ctrl.bgDim.toDouble(),
                        min: 0,
                        max: 85,
                        divisions: 17,
                        onChanged: (v) => ctrl.setBgDim(v.round()),
                      ),
                    ],
                  ),
                ),
              ],
              _section(context, tr('Biblioteca', 'Library')),
              ListTile(
                leading: const Icon(Icons.visibility_off),
                title: Text(tr('Archivos ocultos', 'Hidden files')),
                trailing: Text('${ctrl.hidden.length}'),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const HiddenPage()),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: Text(tr('Eliminados recientemente', 'Recently deleted')),
                trailing: Text('${ctrl.deleted.length}'),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const DeletedPage()),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.refresh),
                title: Text(tr('Buscar canciones nuevas', 'Scan for new songs')),
                onTap: () {
                  ctrl.loadSongs();
                  snack(context, tr('Buscando...', 'Scanning...'));
                },
              ),
              _section(context, tr('Notificaciones', 'Notifications')),
              ListTile(
                leading: const Icon(Icons.notifications),
                title: Text(tr('Notificación del reproductor',
                    'Player notification')),
                subtitle: Text(tr(
                    'Si no aparece en la barra, permite las notificaciones aquí',
                    'If it does not show in the bar, allow notifications here')),
                onTap: () async {
                  await ctrl.checkNotifications(ask: true);
                  try {
                    await AppSettings.openAppSettings(
                        type: AppSettingsType.notification);
                  } catch (_) {}
                },
              ),
              _section(context, tr('Idioma', 'Language')),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'es', label: Text('Español')),
                      ButtonSegment(value: 'en', label: Text('English')),
                    ],
                    selected: {ctrl.lang},
                    onSelectionChanged: (s) => ctrl.setLang(s.first),
                  ),
                ),
              ),
              const SizedBox(height: 32),
            ],
          ),
        );
      },
    );
  }
}

class HiddenPage extends StatelessWidget {
  const HiddenPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ctrl,
      builder: (context, _) {
        final list = ctrl.all.where((t) => ctrl.hidden.contains(t.id)).toList();
        return Scaffold(
          appBar: AppBar(title: Text(tr('Archivos ocultos', 'Hidden files'))),
          body: list.isEmpty
              ? Center(
                  child: Text(tr('No hay archivos ocultos', 'No hidden files')))
              : ListView.builder(
                  itemCount: list.length,
                  itemBuilder: (context, i) => ListTile(
                    leading: TrackArt(track: list[i], size: 50),
                    title: Text(list[i].title,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(list[i].artist),
                    trailing: TextButton(
                      onPressed: () => ctrl.unhide(list[i].id),
                      child: Text(tr('Mostrar', 'Show')),
                    ),
                  ),
                ),
        );
      },
    );
  }
}

class DeletedPage extends StatelessWidget {
  const DeletedPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ctrl,
      builder: (context, _) {
        final list = ctrl.all.where((t) => ctrl.deleted.contains(t.id)).toList();
        return Scaffold(
          appBar: AppBar(
              title: Text(tr('Eliminados recientemente', 'Recently deleted'))),
          body: list.isEmpty
              ? Center(child: Text(tr('Nada eliminado', 'Nothing deleted')))
              : ListView.builder(
                  itemCount: list.length,
                  itemBuilder: (context, i) => ListTile(
                    leading: TrackArt(track: list[i], size: 50),
                    title: Text(list[i].title,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(list[i].artist),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: tr('Recuperar', 'Restore'),
                          icon: const Icon(Icons.restore),
                          onPressed: () => ctrl.restore(list[i].id),
                        ),
                        IconButton(
                          tooltip: tr('Borrar el archivo', 'Delete the file'),
                          icon: const Icon(Icons.delete_forever),
                          onPressed: () async {
                            final ok = await ctrl.deleteFile(list[i]);
                            snack(
                              context,
                              ok
                                  ? tr('Archivo borrado.', 'File deleted.')
                                  : tr('Android no me deja borrar este archivo. Sigue oculto en tu app.',
                                      'Android does not let me delete this file. It stays hidden in your app.'),
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ),
        );
      },
    );
  }
}
