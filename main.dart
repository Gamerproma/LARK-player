import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:app_settings/app_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:on_audio_query_forked/on_audio_query.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:webview_flutter/webview_flutter.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await JustAudioBackground.init(
    androidNotificationChannelId: 'com.mimusica.audio',
    androidNotificationChannelName: 'Mi Música',
    androidNotificationOngoing: true,
  );
  await ctrl.init();
  runApp(const MiMusicaApp());
}

// ===========================================================================
// DATOS
// ===========================================================================
const accents = <Color>[
  Colors.deepPurple,
  Colors.blue,
  Colors.teal,
  Colors.pink,
  Colors.orange,
  Colors.green,
];

String tr(String es, String en) => ctrl.lang == 'es' ? es : en;

String lastSeg(String path) => path.split(RegExp(r'[\\/]')).last;

String fmt(Duration d) {
  final m = d.inMinutes;
  final s = d.inSeconds % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}

void snack(BuildContext c, String m) {
  ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(m)));
}

class Track {
  final int id;
  final int? msId; // id de la biblioteca de Android (null si es una descarga)
  final String title;
  final String artist;
  final String path;
  final String uri;
  final int durationMs;
  const Track({
    required this.id,
    required this.msId,
    required this.title,
    required this.artist,
    required this.path,
    required this.uri,
    required this.durationMs,
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

// ===========================================================================
// CEREBRO DE LA APP
// ===========================================================================
class Controller extends ChangeNotifier {
  final equalizer = AndroidEqualizer();
  late final AudioPlayer player = AudioPlayer(
    audioPipeline: AudioPipeline(androidAudioEffects: [equalizer]),
  );
  final query = OnAudioQuery();
  late SharedPreferences prefs;

  List<Track> all = [];
  List<Track> tracks = [];
  List<Track> queue = [];
  Set<int> hidden = {};
  Set<int> deleted = {};
  Map<String, List<int>> playlists = {};
  Map<String, int> plays = {};
  String? bgPath;
  bool hasPermission = false;
  bool loading = true;
  bool videoActive = false;

  // Ajustes
  String lang = 'es';
  String themeMode = 'dark';
  int accent = 0;
  bool vinylOnRotate = true;
  bool rememberModes = true;
  int minSeconds = 30;
  double speed = 1.0;
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
    vinylOnRotate = prefs.getBool('vinyl') ?? true;
    rememberModes = prefs.getBool('remember') ?? true;
    minSeconds = prefs.getInt('minSeconds') ?? 30;
    speed = prefs.getDouble('speed') ?? 1.0;

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
    hidden = (jsonDecode(prefs.getString('hidden') ?? '[]') as List)
        .map((e) => e as int)
        .toSet();
    deleted = (jsonDecode(prefs.getString('deleted') ?? '[]') as List)
        .map((e) => e as int)
        .toSet();

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
      }
      notifyListeners();
    });
  }

  // ----- Biblioteca -----
  Future<Directory> downloadsDir() async {
    final base = await getApplicationDocumentsDirectory();
    final d = Directory('${base.path}/Descargas');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  void _refilter() {
    tracks = all
        .where((t) =>
            !hidden.contains(t.id) &&
            !deleted.contains(t.id) &&
            (t.msId == null || t.durationMs >= minSeconds * 1000))
        .toList();
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
          title: s.title,
          artist: (art == null || art == '<unknown>')
              ? tr('Desconocido', 'Unknown')
              : art,
          path: s.data,
          uri: s.uri!,
          durationMs: s.duration ?? 0,
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
          title: dot > 0 ? name.substring(0, dot) : name,
          artist: tr('Descargas', 'Downloads'),
          path: f.path,
          uri: Uri.file(f.path).toString(),
          durationMs: 0,
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
    final sources = queue
        .map((t) => AudioSource.uri(
              Uri.parse(t.uri),
              tag: MediaItem(id: '${t.id}', title: t.title, artist: t.artist),
            ))
        .toList();
    try {
      await player.setAudioSource(
        ConcatenatingAudioSource(children: sources),
        initialIndex: index,
      );
      await player.setSpeed(speed);
      player.play();
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

  Future<bool> deleteForever(Track t) async {
    try {
      await File(t.path).delete();
      deleted.remove(t.id);
      all.removeWhere((x) => x.id == t.id);
      _saveSets();
      return true;
    } catch (_) {
      return false;
    }
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
      req.headers.set('User-Agent', 'MiMusica/2.0');
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

  // ----- Descarga por URL (solo enlaces directos a archivos de audio) -----
  Future<String> downloadUrl(String url, void Function(double?) onProgress) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) {
      return tr('Ese enlace no es válido.', 'That link is not valid.');
    }
    final host = uri.host.toLowerCase();
    const blocked = [
      'youtube.com',
      'youtu.be',
      'instagram.com',
      'facebook.com',
      'fb.watch',
      'tiktok.com',
    ];
    if (blocked.any((b) => host == b || host.endsWith('.$b'))) {
      return tr(
        'Esos sitios no permiten descargar su contenido. Usa un enlace directo a un archivo de audio (.mp3, .m4a...).',
        'Those sites do not allow downloading their content. Use a direct link to an audio file (.mp3, .m4a...).',
      );
    }
    final client = HttpClient();
    try {
      final req = await client.getUrl(uri);
      final res = await req.close();
      if (res.statusCode != 200) {
        return tr('El servidor respondió con error ${res.statusCode}.',
            'The server answered with error ${res.statusCode}.');
      }
      final type = res.headers.contentType?.mimeType ?? '';
      final low = uri.path.toLowerCase();
      const exts = ['.mp3', '.m4a', '.aac', '.wav', '.ogg', '.flac', '.opus'];
      final okExt = exts.any((e) => low.endsWith(e));
      if (!type.startsWith('audio') &&
          !okExt &&
          type != 'application/octet-stream') {
        return tr('Ese enlace no parece ser un archivo de audio.',
            'That link does not look like an audio file.');
      }
      final dir = await downloadsDir();
      var name = uri.pathSegments.isNotEmpty
          ? Uri.decodeComponent(uri.pathSegments.last)
          : 'cancion_${DateTime.now().millisecondsSinceEpoch}.mp3';
      if (!name.contains('.')) name = '$name.mp3';
      name = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      final file = File('${dir.path}/$name');
      final sink = file.openWrite();
      var got = 0;
      final total = res.contentLength;
      await for (final chunk in res) {
        sink.add(chunk);
        got += chunk.length;
        onProgress(total > 0 ? got / total : null);
      }
      await sink.close();
      await loadSongs();
      return tr('Listo: $name (revisa la pestaña Canciones)',
          'Done: $name (check the Songs tab)');
    } catch (e) {
      return tr('No se pudo descargar: $e', 'Could not download: $e');
    } finally {
      client.close();
    }
  }
}

final ctrl = Controller();

// ===========================================================================
// APP Y PANTALLA PRINCIPAL
// ===========================================================================
class MiMusicaApp extends StatelessWidget {
  const MiMusicaApp({super.key});

  ThemeData _theme(Brightness b) => ThemeData(
        useMaterial3: true,
        colorScheme:
            ColorScheme.fromSeed(seedColor: accents[ctrl.accent], brightness: b),
      );

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ctrl,
      builder: (context, _) => MaterialApp(
        title: 'Mi Música',
        debugShowCheckedModeBanner: false,
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

class _RootState extends State<Root> {
  @override
  void initState() {
    super.initState();
    ctrl.loadSongs();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ctrl,
      builder: (context, _) {
        final surface = Theme.of(context).colorScheme.surface;
        return Stack(
          fit: StackFit.expand,
          children: [
            if (ctrl.bgPath != null)
              Image.file(File(ctrl.bgPath!), fit: BoxFit.cover),
            Container(color: surface.withAlpha(ctrl.bgPath != null ? 150 : 255)),
            DefaultTabController(
              length: 5,
              initialIndex: 1,
              child: Scaffold(
                backgroundColor: Colors.transparent,
                appBar: AppBar(
                  backgroundColor: Colors.transparent,
                  title: const Text('Mi Música'),
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
                        MaterialPageRoute(builder: (_) => const SettingsPage()),
                      ),
                    ),
                  ],
                  bottom: TabBar(
                    isScrollable: true,
                    tabAlignment: TabAlignment.start,
                    tabs: [
                      const Tab(text: 'Videos'),
                      Tab(text: tr('Canciones', 'Songs')),
                      const Tab(text: 'Playlists'),
                      Tab(text: tr('Carpetas', 'Folders')),
                      Tab(text: tr('Artistas', 'Artists')),
                    ],
                  ),
                ),
                body: TabBarView(
                  children: [
                    const VideosTab(),
                    const SongsTab(),
                    const PlaylistsTab(),
                    GroupTab(isFolder: true),
                    GroupTab(isFolder: false),
                  ],
                ),
                bottomNavigationBar: const MiniPlayer(),
              ),
            ),
          ],
        );
      },
    );
  }
}

// ===========================================================================
// PIEZAS REUTILIZABLES
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

  Widget get _placeholder => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: Colors.white12,
          borderRadius: BorderRadius.circular(radius),
        ),
        child: Icon(Icons.music_note, size: size * 0.5),
      );

  @override
  Widget build(BuildContext context) {
    if (track.msId == null) return _placeholder;
    return QueryArtworkWidget(
      id: track.msId!,
      type: ArtworkType.AUDIO,
      size: size > 100 ? 600 : 200,
      artworkWidth: size,
      artworkHeight: size,
      artworkFit: BoxFit.cover,
      artworkBorder: BorderRadius.circular(radius),
      nullArtworkWidget: _placeholder,
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
        if (context.mounted) {
          snack(context, tr('No pude compartir este archivo.',
              'Could not share this file.'));
        }
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
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(tr('¿Borrar esta canción?', 'Delete this song?')),
          content: Text(tr(
              'Irá a "Eliminados recientemente" y podrás recuperarla.',
              'It will go to "Recently deleted" and you can restore it.')),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr('Cancelar', 'Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr('Borrar', 'Delete')),
            ),
          ],
        ),
      );
      if (ok == true) ctrl.softDelete(t);
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
    return ListTile(
      onTap: onTap,
      leading: TrackArt(track: track, size: 50),
      title: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle:
          Text(track.artist, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: trailing ?? trackMenu(context, track),
    );
  }
}

// ===========================================================================
// PESTAÑA: CANCIONES
// ===========================================================================
class SongsTab extends StatelessWidget {
  const SongsTab({super.key});

  @override
  Widget build(BuildContext context) {
    if (ctrl.loading && ctrl.all.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
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
          if (i == 0) {
            return ListTile(
              leading: const Icon(Icons.shuffle),
              title: Text(tr('Reproducir todo en aleatorio',
                  'Shuffle play everything')),
              onTap: ctrl.playAllShuffled,
            );
          }
          final t = ctrl.tracks[i - 1];
          return TrackTile(
            track: t,
            onTap: () => ctrl.playList(ctrl.tracks, i - 1),
          );
        },
      ),
    );
  }
}

// ===========================================================================
// PESTAÑAS: CARPETAS Y ARTISTAS
// ===========================================================================
class GroupTab extends StatelessWidget {
  final bool isFolder;
  const GroupTab({super.key, required this.isFolder});

  @override
  Widget build(BuildContext context) {
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
        final name = isFolder ? lastSeg(k) : k;
        return ListTile(
          leading: Icon(isFolder ? Icons.folder : Icons.person),
          title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text('${groups[k]!.length} ${tr('canciones', 'songs')}'),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => TrackListPage(name, groups[k]!),
            ),
          ),
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
                subtitle:
                    Text('${ctrl.playlists[n]!.length} ${tr('canciones', 'songs')}'),
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
    if (_items == null) {
      return const Center(child: CircularProgressIndicator());
    }
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
                  future: a.thumbnailDataWithSize(const ThumbnailSize(300, 300)),
                  builder: (context, s) => s.data == null
                      ? Container(color: Colors.white12)
                      : Image.memory(s.data!, fit: BoxFit.cover),
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
              ? const Center(child: CircularProgressIndicator())
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
// MINI REPRODUCTOR
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
        return Material(
          color: Theme.of(context).colorScheme.surfaceContainer,
          child: SafeArea(
            top: false,
            child: ListTile(
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const NowPlayingPage()),
              ),
              leading: TrackArt(track: s, size: 44),
              title:
                  Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle:
                  Text(s.artist, maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: const PlayPauseButton(),
            ),
          ),
        );
      },
    );
  }
}

// ===========================================================================
// REPRODUCTOR GRANDE (con letras)
// ===========================================================================
class NowPlayingPage extends StatefulWidget {
  const NowPlayingPage({super.key});
  @override
  State<NowPlayingPage> createState() => _NowPlayingPageState();
}

class _NowPlayingPageState extends State<NowPlayingPage> {
  bool _lyrics = false;

  @override
  Widget build(BuildContext context) {
    final p = ctrl.player;
    return StreamBuilder<int?>(
      stream: p.currentIndexStream,
      builder: (context, snap) {
        final s = ctrl.current;
        if (s == null) {
          return Scaffold(
            appBar: AppBar(),
            body: Center(child: Text(tr('No hay nada sonando', 'Nothing playing'))),
          );
        }
        return Scaffold(
          appBar: AppBar(
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
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                Expanded(
                  child: _lyrics
                      ? LyricsView(s)
                      : Center(child: TrackArt(track: s, size: 280)),
                ),
                const SizedBox(height: 8),
                Text(
                  s.title,
                  style: Theme.of(context).textTheme.titleLarge,
                  maxLines: 2,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(s.artist),
                const SizedBox(height: 8),
                StreamBuilder<Duration>(
                  stream: p.positionStream,
                  builder: (context, snap) {
                    final pos = snap.data ?? Duration.zero;
                    final dur = p.duration ?? Duration.zero;
                    final max = dur.inMilliseconds > 0
                        ? dur.inMilliseconds.toDouble()
                        : 1.0;
                    final val = pos.inMilliseconds
                        .toDouble()
                        .clamp(0.0, max)
                        .toDouble();
                    return Column(
                      children: [
                        Slider(
                          value: val,
                          max: max,
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
                          color: (snap.data ?? false)
                              ? Theme.of(context).colorScheme.primary
                              : null,
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
                            m == LoopMode.one ? Icons.repeat_one : Icons.repeat,
                            color: m == LoopMode.off
                                ? null
                                : Theme.of(context).colorScheme.primary,
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
          return const Center(child: CircularProgressIndicator());
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
// ECUALIZADOR
// ===========================================================================
class EqualizerPage extends StatelessWidget {
  const EqualizerPage({super.key});

  String _hz(double f) =>
      f >= 1000 ? '${(f / 1000).toStringAsFixed(1)} kHz' : '${f.round()} Hz';

  @override
  Widget build(BuildContext context) {
    final eq = ctrl.equalizer;
    return Scaffold(
      appBar: AppBar(title: Text(tr('Ecualizador', 'Equalizer'))),
      body: ctrl.queue.isEmpty
          ? Center(
              child: Text(tr('Primero pon una canción y vuelve aquí.',
                  'Play a song first and come back here.')),
            )
          : FutureBuilder<AndroidEqualizerParameters>(
              future: eq.parameters,
              builder: (context, snap) {
                final params = snap.data;
                if (params == null) {
                  return const Center(child: CircularProgressIndicator());
                }
                return ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    StreamBuilder<bool>(
                      stream: eq.enabledStream,
                      builder: (context, s) => SwitchListTile(
                        title: Text(tr('Activar ecualizador', 'Enable equalizer')),
                        value: s.data ?? false,
                        onChanged: eq.setEnabled,
                      ),
                    ),
                    for (final band in params.bands)
                      StreamBuilder<double>(
                        stream: band.gainStream,
                        builder: (context, s) => Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(_hz(band.centerFrequency)),
                            Slider(
                              min: params.minDecibels,
                              max: params.maxDecibels,
                              value: s.data ?? band.gain,
                              onChanged: band.setGain,
                            ),
                          ],
                        ),
                      ),
                    TextButton.icon(
                      onPressed: () {
                        for (final b in params.bands) {
                          b.setGain(0);
                        }
                      },
                      icon: const Icon(Icons.restart_alt),
                      label: Text(tr('Restablecer', 'Reset')),
                    ),
                  ],
                );
              },
            ),
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
              if (t != null) TrackArt(track: t, size: 120),
              const SizedBox(height: 8),
              if (t != null) Text(t.title, style: Theme.of(context).textTheme.titleMedium),
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
// MODO GIRATORIO: DISCO DE VINILO (al poner el teléfono en horizontal)
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
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
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
    );
  }
}

// ===========================================================================
// BUSCADOR + SITIOS + DESCARGA POR URL
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

  @override
  Widget build(BuildContext context) {
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
          autofocus: false,
          decoration: InputDecoration(
            hintText: tr('Buscar canciones o sitios', 'Search songs or sites'),
            border: InputBorder.none,
          ),
          onChanged: (v) => setState(() => _q = v),
        ),
      ),
      body: ListView(
        children: [
          Card(
            margin: const EdgeInsets.all(12),
            color: Theme.of(context).colorScheme.primaryContainer,
            child: ListTile(
              leading: const Icon(Icons.download),
              title: Text(tr('Descargar por URL', 'Download by URL'),
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text(tr('Pega un enlace directo a un archivo de audio',
                  'Paste a direct link to an audio file')),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const DownloadPage()),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
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
              ],
            ),
          ),
          if (q.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
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
  late final WebViewController _c = WebViewController()
    ..setJavaScriptMode(JavaScriptMode.unrestricted)
    ..loadRequest(Uri.parse(widget.url));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: WebViewWidget(controller: _c),
    );
  }
}

class DownloadPage extends StatefulWidget {
  const DownloadPage({super.key});
  @override
  State<DownloadPage> createState() => _DownloadPageState();
}

class _DownloadPageState extends State<DownloadPage> {
  final _t = TextEditingController();
  bool _busy = false;
  double? _progress;
  String _msg = '';

  Future<void> _paste() async {
    final d = await Clipboard.getData('text/plain');
    if (d?.text != null) setState(() => _t.text = d!.text!.trim());
  }

  Future<void> _go() async {
    if (_t.text.trim().isEmpty) return;
    setState(() {
      _busy = true;
      _progress = null;
      _msg = '';
    });
    final r = await ctrl.downloadUrl(_t.text, (p) {
      if (mounted) setState(() => _progress = p);
    });
    if (mounted) {
      setState(() {
        _busy = false;
        _msg = r;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr('Descargar por URL', 'Download by URL'))),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(tr(
              'Pega un enlace directo a un archivo de audio (termina en .mp3, .m4a, etc.). Descarga solo música que tengas derecho a guardar.',
              'Paste a direct link to an audio file (ends in .mp3, .m4a, etc.). Only download music you have the right to keep.',
            )),
            const SizedBox(height: 12),
            TextField(
              controller: _t,
              keyboardType: TextInputType.url,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                hintText: 'https://...',
                suffixIcon: IconButton(
                  icon: const Icon(Icons.paste),
                  onPressed: _paste,
                ),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _busy ? null : _go,
              icon: const Icon(Icons.download),
              label: Text(tr('Descargar', 'Download')),
            ),
            const SizedBox(height: 16),
            if (_busy) LinearProgressIndicator(value: _progress),
            if (_msg.isNotEmpty) Text(_msg),
          ],
        ),
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
              if (ctrl.bgPath != null)
                ListTile(
                  leading: const Icon(Icons.hide_image),
                  title: Text(tr('Quitar fondo', 'Remove background')),
                  onTap: ctrl.clearBackground,
                ),
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
                title: Text(tr('Configuración de notificaciones',
                    'Notification settings')),
                subtitle: Text(tr('Abre los ajustes de Android para esta app',
                    'Opens Android settings for this app')),
                onTap: () async {
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
              ? Center(child: Text(tr('No hay archivos ocultos', 'No hidden files')))
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
                          tooltip: tr('Borrar para siempre', 'Delete forever'),
                          icon: const Icon(Icons.delete_forever),
                          onPressed: () async {
                            final ok = await ctrl.deleteForever(list[i]);
                            if (!ok && context.mounted) {
                              snack(
                                context,
                                tr('Android no me deja borrar este archivo. Sigue oculto en tu app.',
                                    'Android does not let me delete this file. It stays hidden in your app.'),
                              );
                            }
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
