import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:on_audio_query_forked/on_audio_query.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await JustAudioBackground.init(
    androidNotificationChannelId: 'com.mimusica.audio',
    androidNotificationChannelName: 'Mi Música',
    androidNotificationOngoing: true,
  );
  runApp(const MiMusicaApp());
}

// ---------------------------------------------------------------------------
// CEREBRO DE LA APP: guarda canciones, listas, fondo y controla la música
// ---------------------------------------------------------------------------
class Controller extends ChangeNotifier {
  final equalizer = AndroidEqualizer();
  late final AudioPlayer player = AudioPlayer(
    audioPipeline: AudioPipeline(androidAudioEffects: [equalizer]),
  );
  final query = OnAudioQuery();

  List<SongModel> songs = [];
  List<SongModel> queue = [];
  Map<String, List<int>> playlists = {};
  Map<String, int> plays = {}; // cuántas veces escuchas cada canción
  String? bgPath;
  bool hasPermission = false;
  bool loading = true;
  late SharedPreferences prefs;

  Future<void> init() async {
    prefs = await SharedPreferences.getInstance();

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

    player.currentIndexStream.listen((i) {
      if (i != null && i < queue.length) {
        final k = '${queue[i].id}';
        plays[k] = (plays[k] ?? 0) + 1;
        prefs.setString('plays', jsonEncode(plays));
      }
      notifyListeners();
    });

    await loadSongs();
  }

  Future<void> loadSongs() async {
    loading = true;
    notifyListeners();
    hasPermission = await query.permissionsStatus();
    if (!hasPermission) hasPermission = await query.permissionsRequest();
    if (hasPermission) {
      final all = await query.querySongs(
        sortType: SongSortType.TITLE,
        orderType: OrderType.ASC_OR_SMALLER,
        uriType: UriType.EXTERNAL,
        ignoreCase: true,
      );
      // Solo canciones de más de 30 segundos (así no salen tonos de llamada)
      songs = all.where((s) => (s.duration ?? 0) > 30000).toList();
    }
    loading = false;
    notifyListeners();
  }

  Future<void> playList(List<SongModel> list, int index) async {
    queue = list;
    final sources = list
        .map((s) => AudioSource.uri(
              Uri.parse(s.uri!),
              tag: MediaItem(
                id: '${s.id}',
                title: s.title,
                artist: s.artist ?? 'Desconocido',
              ),
            ))
        .toList();
    await player.setAudioSource(
      ConcatenatingAudioSource(children: sources),
      initialIndex: index,
    );
    player.play();
  }

  Future<void> playAllShuffled() async {
    if (songs.isEmpty) return;
    await playList(songs, Random().nextInt(songs.length));
    await player.shuffle();
    await player.setShuffleModeEnabled(true);
    notifyListeners();
  }

  Future<void> toggleShuffle() async {
    final on = !player.shuffleModeEnabled;
    if (on) await player.shuffle();
    await player.setShuffleModeEnabled(on);
    notifyListeners();
  }

  Future<void> cycleRepeat() async {
    final next = {
      LoopMode.off: LoopMode.all,
      LoopMode.all: LoopMode.one,
      LoopMode.one: LoopMode.off,
    }[player.loopMode]!;
    await player.setLoopMode(next);
    notifyListeners();
  }

  // ----- Fondo de pantalla -----
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

  // ----- Listas de reproducción -----
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

  void addToPlaylist(String name, int songId) {
    final l = playlists[name];
    if (l == null || l.contains(songId)) return;
    l.add(songId);
    _savePlaylists();
  }

  void removeFromPlaylist(String name, int songId) {
    playlists[name]?.remove(songId);
    _savePlaylists();
  }
}

final ctrl = Controller();

// ---------------------------------------------------------------------------
// APP
// ---------------------------------------------------------------------------
class MiMusicaApp extends StatelessWidget {
  const MiMusicaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Mi Música',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepPurple,
          brightness: Brightness.dark,
        ),
      ),
      home: const Root(),
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
    ctrl.init();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ctrl,
      builder: (context, _) {
        return Stack(
          fit: StackFit.expand,
          children: [
            if (ctrl.bgPath != null)
              Image.file(File(ctrl.bgPath!), fit: BoxFit.cover)
            else
              Container(color: const Color(0xFF121212)),
            Container(color: Colors.black.withOpacity(0.55)),
            DefaultTabController(
              length: 2,
              child: Scaffold(
                backgroundColor: Colors.transparent,
                appBar: AppBar(
                  backgroundColor: Colors.transparent,
                  title: const Text('Mi Música'),
                  actions: [
                    IconButton(
                      icon: const Icon(Icons.wallpaper),
                      tooltip: 'Cambiar fondo',
                      onPressed: ctrl.pickBackground,
                    ),
                    IconButton(
                      icon: const Icon(Icons.refresh),
                      tooltip: 'Buscar canciones nuevas',
                      onPressed: ctrl.loadSongs,
                    ),
                  ],
                  bottom: const TabBar(
                    tabs: [Tab(text: 'Canciones'), Tab(text: 'Listas')],
                  ),
                ),
                body: const TabBarView(children: [SongsTab(), PlaylistsTab()]),
                bottomNavigationBar: const MiniPlayer(),
              ),
            ),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// PIEZAS REUTILIZABLES
// ---------------------------------------------------------------------------
class Art extends StatelessWidget {
  final int id;
  final double size;
  const Art({super.key, required this.id, required this.size});

  @override
  Widget build(BuildContext context) {
    return QueryArtworkWidget(
      id: id,
      type: ArtworkType.AUDIO,
      size: size > 100 ? 600 : 200,
      artworkWidth: size,
      artworkHeight: size,
      artworkFit: BoxFit.cover,
      artworkBorder: BorderRadius.circular(8),
      nullArtworkWidget: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: Colors.white12,
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Icon(Icons.music_note),
      ),
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
    builder: (_) => AlertDialog(
      title: const Text('Nombre de la lista'),
      content: TextField(controller: t, autofocus: true),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, t.text.trim()),
          child: const Text('Crear'),
        ),
      ],
    ),
  );
}

void addToPlaylistSheet(BuildContext context, SongModel s) {
  showModalBottomSheet(
    context: context,
    builder: (_) => ListView(
      children: [
        ListTile(
          leading: const Icon(Icons.add),
          title: const Text('Nueva lista'),
          onTap: () async {
            Navigator.pop(context);
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
              Navigator.pop(context);
            },
          ),
      ],
    ),
  );
}

class SongTile extends StatelessWidget {
  final SongModel song;
  final VoidCallback onTap;
  final Widget? trailing;
  const SongTile({
    super.key,
    required this.song,
    required this.onTap,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      leading: Art(id: song.id, size: 50),
      title: Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        song.artist ?? 'Desconocido',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: trailing ??
          IconButton(
            icon: const Icon(Icons.more_vert),
            tooltip: 'Añadir a una lista',
            onPressed: () => addToPlaylistSheet(context, song),
          ),
    );
  }
}

// ---------------------------------------------------------------------------
// PESTAÑA: CANCIONES
// ---------------------------------------------------------------------------
class SongsTab extends StatelessWidget {
  const SongsTab({super.key});

  @override
  Widget build(BuildContext context) {
    if (ctrl.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (!ctrl.hasPermission) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Necesito permiso para ver tu música'),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: ctrl.loadSongs,
              child: const Text('Dar permiso'),
            ),
          ],
        ),
      );
    }
    if (ctrl.songs.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'No encontré canciones. Descarga música y toca el botón de actualizar (arriba a la derecha).',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return Column(
      children: [
        ListTile(
          leading: const Icon(Icons.shuffle),
          title: const Text('Reproducir todo en aleatorio'),
          onTap: ctrl.playAllShuffled,
        ),
        Expanded(
          child: ListView.builder(
            itemCount: ctrl.songs.length,
            itemBuilder: (context, i) => SongTile(
              song: ctrl.songs[i],
              onTap: () => ctrl.playList(ctrl.songs, i),
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// PESTAÑA: LISTAS
// ---------------------------------------------------------------------------
class PlaylistsTab extends StatelessWidget {
  const PlaylistsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final names = ctrl.playlists.keys.toList();
    return Column(
      children: [
        ListTile(
          leading: const Icon(Icons.add),
          title: const Text('Nueva lista'),
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
                subtitle: Text('${ctrl.playlists[n]!.length} canciones'),
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
        final ids = ctrl.playlists[name] ?? [];
        final list = [
          for (final id in ids) ...ctrl.songs.where((s) => s.id == id),
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
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'Lista vacía. Agrega canciones con los tres puntos (⋮) en la pestaña Canciones.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView.builder(
                  itemCount: list.length,
                  itemBuilder: (context, i) => SongTile(
                    song: list[i],
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

// ---------------------------------------------------------------------------
// MINI REPRODUCTOR (barra de abajo)
// ---------------------------------------------------------------------------
class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<int?>(
      stream: ctrl.player.currentIndexStream,
      builder: (context, snap) {
        final i = snap.data;
        if (i == null || i >= ctrl.queue.length) {
          return const SizedBox.shrink();
        }
        final s = ctrl.queue[i];
        return Material(
          color: Colors.black87,
          child: SafeArea(
            top: false,
            child: ListTile(
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const NowPlayingPage()),
              ),
              leading: Art(id: s.id, size: 44),
              title:
                  Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                s.artist ?? 'Desconocido',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: const PlayPauseButton(),
            ),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// PANTALLA GRANDE DEL REPRODUCTOR
// ---------------------------------------------------------------------------
class NowPlayingPage extends StatelessWidget {
  const NowPlayingPage({super.key});

  @override
  Widget build(BuildContext context) {
    final p = ctrl.player;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Reproduciendo'),
        actions: [
          IconButton(
            icon: const Icon(Icons.equalizer),
            tooltip: 'Ecualizador',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const EqualizerPage()),
            ),
          ),
        ],
      ),
      body: StreamBuilder<int?>(
        stream: p.currentIndexStream,
        builder: (context, snap) {
          final i = snap.data;
          if (i == null || i >= ctrl.queue.length) {
            return const Center(child: Text('No hay nada sonando'));
          }
          final s = ctrl.queue[i];
          return Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                Expanded(child: Center(child: Art(id: s.id, size: 280))),
                Text(
                  s.title,
                  style: Theme.of(context).textTheme.titleLarge,
                  maxLines: 2,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(s.artist ?? 'Desconocido'),
                const SizedBox(height: 16),
                StreamBuilder<Duration>(
                  stream: p.positionStream,
                  builder: (context, snap) {
                    final pos = snap.data ?? Duration.zero;
                    final dur = p.duration ?? Duration.zero;
                    final max = dur.inMilliseconds > 0
                        ? dur.inMilliseconds.toDouble()
                        : 1.0;
                    final val =
                        pos.inMilliseconds.toDouble().clamp(0.0, max).toDouble();
                    return Slider(
                      value: val,
                      max: max,
                      onChanged: (v) =>
                          p.seek(Duration(milliseconds: v.round())),
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
                              ? Colors.deepPurpleAccent
                              : Colors.white,
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
                                ? Colors.white
                                : Colors.deepPurpleAccent,
                          ),
                          onPressed: ctrl.cycleRepeat,
                        );
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 24),
              ],
            ),
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// ECUALIZADOR
// ---------------------------------------------------------------------------
class EqualizerPage extends StatelessWidget {
  const EqualizerPage({super.key});

  @override
  Widget build(BuildContext context) {
    final eq = ctrl.equalizer;
    return Scaffold(
      appBar: AppBar(title: const Text('Ecualizador')),
      body: ctrl.queue.isEmpty
          ? const Center(child: Text('Primero pon una canción y vuelve aquí.'))
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
                        title: const Text('Activar ecualizador'),
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
                            Text('${band.centerFrequency.round()} Hz'),
                            Slider(
                              min: params.minDecibels,
                              max: params.maxDecibels,
                              value: s.data ?? band.gain,
                              onChanged: band.setGain,
                            ),
                          ],
                        ),
                      ),
                  ],
                );
              },
            ),
    );
  }
}
