import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';


void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

// ==================== SONG MODEL ====================
class Song {
  final String id;
  final String name;
  final String path;
  final String artist;
  final int duration;
  bool isFavorite;

  Song({
    required this.id,
    required this.name,
    required this.path,
    required this.artist,
    required this.duration,
    this.isFavorite = false,
  });
}

// ==================== REPEAT MODE ENUM ====================
enum RepeatMode { none, one, all }

// ==================== AUDIO PROVIDER ====================
class AudioProvider extends ChangeNotifier {
  final AudioPlayer _audioPlayer = AudioPlayer();

  List<Song> _songs = [];
  List<Song> _filteredSongs = [];
  Song? _currentSong;
  Duration _currentPosition = Duration.zero;
  Duration _totalDuration = Duration.zero;
  bool _isPlaying = false;
  RepeatMode _repeatMode = RepeatMode.none;
  bool _isShuffle = false;
  String _searchQuery = '';
  bool _isLoading = true;
  bool _isSeeking = false;
  bool _hasPermission = false;

  AudioProvider() {
    _init();
  }

  Future<void> _init() async {
    await checkPermissionAndLoadSongs();
    _initListeners();
  }

  /// Requests the correct storage permission based on Android SDK version.
  /// Android 13+ (API 33+): uses READ_MEDIA_AUDIO
  /// Android 12 and below:  uses READ_EXTERNAL_STORAGE
  /// iOS: uses mediaLibrary
  Future<bool> _requestStoragePermission() async {
    if (Platform.isIOS) {
      final status = await Permission.mediaLibrary.request();
      debugPrint('iOS mediaLibrary permission: $status');
      return status.isGranted;
    }

    if (Platform.isAndroid) {
      final androidInfo = await DeviceInfoPlugin().androidInfo;
      final sdkInt = androidInfo.version.sdkInt;
      debugPrint('Android SDK version: $sdkInt');

      if (sdkInt >= 33) {
        // Android 13+ — READ_MEDIA_AUDIO replaces READ_EXTERNAL_STORAGE
        final status = await Permission.audio.request();
        debugPrint('Android 13+ audio permission: $status');
        return status.isGranted;
      } else {
        // Android 12 and below
        final status = await Permission.storage.request();
        debugPrint('Android <=12 storage permission: $status');
        return status.isGranted;
      }
    }

    return false;
  }

  Future<void> checkPermissionAndLoadSongs() async {
    _isLoading = true;
    notifyListeners();

    final granted = await _requestStoragePermission();

    if (granted) {
      _hasPermission = true;
      await loadDeviceSongs();
    } else {
      _hasPermission = false;
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> loadDeviceSongs() async {
    try {
      _isLoading = true;
      notifyListeners();

      _songs = await scanAudioFiles();

      await _loadFavorites();
      _filteredSongs = List.from(_songs);
      _isLoading = false;
      notifyListeners();

      debugPrint('Loaded ${_songs.length} songs from device');
    } catch (e) {
      debugPrint('Error loading device songs: $e');
      _songs = [];
      _filteredSongs = [];
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<List<Song>> scanAudioFiles() async {
    List<Song> audioFiles = [];

    try {
      List<String> paths = [];

      if (Platform.isAndroid) {
        final directories = [
          '/storage/emulated/0/Music',
          '/storage/emulated/0/Download',
          '/storage/emulated/0/Media/Music',
          '/storage/emulated/0/Audio',
          '/storage/emulated/0/Movies',
          '/sdcard/Music',
          '/sdcard/Download',
        ];

        for (String dir in directories) {
          Directory directory = Directory(dir);
          if (await directory.exists()) {
            paths.add(dir);
          }
        }
      } else if (Platform.isIOS) {
        final directory = await getApplicationDocumentsDirectory();
        paths.add(directory.path);
      }

      const audioExtensions = ['.mp3', '.m4a', '.wav', '.aac', '.flac', '.ogg'];

      for (String path in paths) {
        await _scanDirectory(Directory(path), audioFiles, audioExtensions);
      }
    } catch (e) {
      debugPrint('Error scanning files: $e');
    }

    return audioFiles;
  }

  Future<void> _scanDirectory(
      Directory directory, List<Song> audioFiles, List<String> extensions) async {
    try {
      final List<FileSystemEntity> entities = await directory.list().toList();

      for (FileSystemEntity entity in entities) {
        if (entity is File) {
          String filePath = entity.path;
          final dotIndex = filePath.lastIndexOf('.');
          if (dotIndex == -1) continue;
          String extension = filePath.substring(dotIndex).toLowerCase();

          if (extensions.contains(extension)) {
            String fileName = entity.path.split(Platform.pathSeparator).last;
            String songName = fileName.substring(0, fileName.lastIndexOf('.'));

            audioFiles.add(Song(
              id: audioFiles.length.toString(),
              name: songName,
              path: filePath,
              artist: 'Unknown Artist',
              duration: 0,
              isFavorite: false,
            ));
          }
        } else if (entity is Directory) {
          if (audioFiles.length < 1000) {
            await _scanDirectory(entity, audioFiles, extensions);
          }
        }
      }
    } catch (e) {
      debugPrint('Cannot scan directory: ${directory.path}');
    }
  }

  List<Song> get songs => _filteredSongs;
  Song? get currentSong => _currentSong;
  Duration get currentPosition => _currentPosition;
  Duration get totalDuration => _totalDuration;
  bool get isPlaying => _isPlaying;
  RepeatMode get repeatMode => _repeatMode;
  bool get isShuffle => _isShuffle;
  String get searchQuery => _searchQuery;
  bool get isLoading => _isLoading;
  bool get hasPermission => _hasPermission;

  double get progress => _totalDuration.inSeconds > 0
      ? _currentPosition.inSeconds / _totalDuration.inSeconds
      : 0.0;

  void _initListeners() {
    _audioPlayer.positionStream.listen((position) {
      if (!_isSeeking) {
        _currentPosition = position;
        notifyListeners();
      }
    });

    _audioPlayer.durationStream.listen((duration) {
      _totalDuration = duration ?? Duration.zero;
      notifyListeners();
    });

    _audioPlayer.playerStateStream.listen((state) {
      _isPlaying = state.playing;
      notifyListeners();

      if (state.processingState == ProcessingState.completed) {
        _onSongComplete();
      }
    });
  }

  void _onSongComplete() async {
    if (_repeatMode == RepeatMode.one) {
      await _audioPlayer.seek(Duration.zero);
      await _audioPlayer.play();
    } else {
      await nextSong();
    }
  }

  Future<void> _loadFavorites() async {
    final prefs = await SharedPreferences.getInstance();
    final favorites = prefs.getStringList('favorites') ?? [];
    for (var song in _songs) {
      song.isFavorite = favorites.contains(song.id);
    }
  }

  Future<void> _saveFavorites() async {
    final prefs = await SharedPreferences.getInstance();
    final favorites = _songs.where((s) => s.isFavorite).map((s) => s.id).toList();
    await prefs.setStringList('favorites', favorites);
  }

  void toggleFavorite(Song song) {
    song.isFavorite = !song.isFavorite;
    _saveFavorites();
    notifyListeners();
  }

  void searchSongs(String query) {
    _searchQuery = query;
    if (_searchQuery.isEmpty) {
      _filteredSongs = List.from(_songs);
    } else {
      _filteredSongs = _songs
          .where((song) =>
      song.name.toLowerCase().contains(_searchQuery.toLowerCase()) ||
          song.artist.toLowerCase().contains(_searchQuery.toLowerCase()))
          .toList();
    }
    notifyListeners();
  }

  void toggleShuffle() {
    _isShuffle = !_isShuffle;
    notifyListeners();
  }

  void toggleRepeatMode() {
    switch (_repeatMode) {
      case RepeatMode.none:
        _repeatMode = RepeatMode.all;
        break;
      case RepeatMode.all:
        _repeatMode = RepeatMode.one;
        break;
      case RepeatMode.one:
        _repeatMode = RepeatMode.none;
        break;
    }
    notifyListeners();
  }

  void togglePlayPause() {
    if (_isPlaying) {
      pause();
    } else {
      resume();
    }
  }

  Future<void> playSong(Song song) async {
    try {
      if (_currentSong?.id == song.id && _isPlaying) {
        await pause();
      } else if (_currentSong?.id == song.id && !_isPlaying) {
        await resume();
      } else {
        _currentSong = song;
        await _audioPlayer.setUrl('file://${song.path}');
        await _audioPlayer.play();
        _isPlaying = true;
        notifyListeners();
      }
    } catch (e) {
      debugPrint('Error playing song: $e');
    }
  }

  Future<void> pause() async {
    await _audioPlayer.pause();
    _isPlaying = false;
    notifyListeners();
  }

  Future<void> resume() async {
    await _audioPlayer.play();
    _isPlaying = true;
    notifyListeners();
  }

  Future<void> stop() async {
    await _audioPlayer.stop();
    _currentSong = null;
    _currentPosition = Duration.zero;
    _isPlaying = false;
    notifyListeners();
  }

  Future<void> seekTo(Duration position) async {
    try {
      _isSeeking = true;
      _currentPosition = position;
      notifyListeners();
      await _audioPlayer.seek(position);
      await Future.delayed(const Duration(milliseconds: 100));
      _isSeeking = false;
      notifyListeners();
    } catch (e) {
      debugPrint('Error seeking: $e');
      _isSeeking = false;
      notifyListeners();
    }
  }

  Future<void> previousSong() async {
    if (_songs.isEmpty) return;
    if (_currentSong == null) {
      await playSong(_songs[0]);
      return;
    }
    int currentIndex = _songs.indexWhere((s) => s.id == _currentSong!.id);
    if (currentIndex == -1) {
      await playSong(_songs[0]);
      return;
    }
    int previousIndex = currentIndex - 1;
    if (previousIndex < 0) previousIndex = _songs.length - 1;
    await playSong(_songs[previousIndex]);
  }

  Future<void> nextSong() async {
    if (_songs.isEmpty) return;
    if (_currentSong == null) {
      await playSong(_songs[0]);
      return;
    }
    if (_isShuffle) {
      int randomIndex = DateTime.now().millisecondsSinceEpoch % _songs.length;
      while (_songs[randomIndex].id == _currentSong!.id && _songs.length > 1) {
        randomIndex = (randomIndex + 1) % _songs.length;
      }
      await playSong(_songs[randomIndex]);
    } else {
      int currentIndex = _songs.indexWhere((s) => s.id == _currentSong!.id);
      if (currentIndex == -1) {
        await playSong(_songs[0]);
        return;
      }
      int nextIndex = currentIndex + 1;
      if (nextIndex >= _songs.length) {
        if (_repeatMode == RepeatMode.all) {
          await playSong(_songs[0]);
        } else {
          await stop();
        }
      } else {
        await playSong(_songs[nextIndex]);
      }
    }
  }

  void showFavoritesOnly() {
    _filteredSongs = _songs.where((song) => song.isFavorite).toList();
    notifyListeners();
  }

  void showAllSongs() {
    _filteredSongs = List.from(_songs);
    searchSongs(_searchQuery);
  }

  Future<void> refreshSongs() async {
    await loadDeviceSongs();
  }

  @override
  void dispose() {
    _audioPlayer.dispose();
    super.dispose();
  }
}

// ==================== MAIN APP ====================
class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (context) => AudioProvider(),
      child: MaterialApp(
        title: 'Music Player',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: Brightness.light,
          primarySwatch: Colors.deepPurple,
          useMaterial3: true,
          scaffoldBackgroundColor: Colors.grey.shade50,
          appBarTheme: const AppBarTheme(
            elevation: 0,
            centerTitle: true,
            backgroundColor: Colors.deepPurple,
            foregroundColor: Colors.white,
          ),
        ),
        darkTheme: ThemeData(
          brightness: Brightness.dark,
          primarySwatch: Colors.deepPurple,
          useMaterial3: true,
          scaffoldBackgroundColor: Colors.grey.shade900,
          appBarTheme: const AppBarTheme(
            elevation: 0,
            centerTitle: true,
            backgroundColor: Colors.deepPurple,
          ),
        ),
        themeMode: ThemeMode.system,
        home: const HomeScreen(),
      ),
    );
  }
}

// ==================== HOME SCREEN ====================
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('🎵 Music Player'),
        centerTitle: true,
        actions: [
          Consumer<AudioProvider>(
            builder: (context, provider, child) {
              return IconButton(
                icon: const Icon(Icons.refresh),
                onPressed: () => provider.refreshSongs(),
                tooltip: 'Refresh Songs',
              );
            },
          ),
          Consumer<AudioProvider>(
            builder: (context, provider, child) {
              return PopupMenuButton<String>(
                icon: const Icon(Icons.filter_list),
                onSelected: (value) {
                  if (value == 'favorites') {
                    provider.showFavoritesOnly();
                  } else if (value == 'all') {
                    provider.showAllSongs();
                  }
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(value: 'all', child: Text('All Songs')),
                  const PopupMenuItem(value: 'favorites', child: Text('Favorites')),
                ],
              );
            },
          ),
          Consumer<AudioProvider>(
            builder: (context, provider, child) {
              return IconButton(
                icon: Icon(provider.isShuffle ? Icons.shuffle : Icons.shuffle_outlined),
                onPressed: provider.toggleShuffle,
              );
            },
          ),
          Consumer<AudioProvider>(
            builder: (context, provider, child) {
              IconData repeatIcon;
              switch (provider.repeatMode) {
                case RepeatMode.one:
                  repeatIcon = Icons.repeat_one;
                  break;
                case RepeatMode.all:
                  repeatIcon = Icons.repeat;
                  break;
                default:
                  repeatIcon = Icons.repeat_outlined;
              }
              return IconButton(
                icon: Icon(repeatIcon),
                onPressed: provider.toggleRepeatMode,
              );
            },
          ),
        ],
      ),
      body: const Column(
        children: [
          SearchWidget(),
          Expanded(
            child: SongListWidget(),
          ),
          MiniPlayer(),
        ],
      ),
    );
  }
}

// ==================== SEARCH WIDGET ====================
class SearchWidget extends StatelessWidget {
  const SearchWidget({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<AudioProvider>(
      builder: (context, provider, child) {
        return Padding(
          padding: const EdgeInsets.all(16),
          child: TextField(
            decoration: InputDecoration(
              hintText: '🔍 Search songs by name or artist...',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: provider.searchQuery.isNotEmpty
                  ? IconButton(
                icon: const Icon(Icons.clear),
                onPressed: () => provider.searchSongs(''),
              )
                  : null,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(30),
                borderSide: BorderSide.none,
              ),
              filled: true,
              fillColor: Theme.of(context).cardColor,
            ),
            onChanged: provider.searchSongs,
          ),
        );
      },
    );
  }
}

// ==================== SONG LIST WIDGET ====================
class SongListWidget extends StatelessWidget {
  const SongListWidget({super.key});

  String formatDuration(Duration duration) {
    if (duration.inSeconds <= 0) return '0:00';
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds.remainder(60);
    return "$minutes:${twoDigits(seconds)}";
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AudioProvider>(
      builder: (context, provider, child) {
        if (!provider.hasPermission) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.lock_outline, size: 64, color: Colors.deepPurple),
                const SizedBox(height: 16),
                const Text(
                  'Storage Permission Required',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 32),
                  child: Text(
                    'This app needs permission to access your music files.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey),
                  ),
                ),
                const SizedBox(height: 24),
                ElevatedButton.icon(
                  icon: const Icon(Icons.security),
                  label: const Text('Grant Permission'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.deepPurple,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  ),
                  onPressed: () async {
                    await provider.checkPermissionAndLoadSongs();
                  },
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: () => openAppSettings(),
                  child: const Text('Open App Settings'),
                ),
              ],
            ),
          );
        }

        if (provider.isLoading) {
          return const Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text('Loading songs from device...'),
              ],
            ),
          );
        }

        if (provider.songs.isEmpty) {
          return const Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.music_off, size: 64, color: Colors.grey),
                SizedBox(height: 16),
                Text(
                  'No songs found on device',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                SizedBox(height: 8),
                Text(
                  'Please add some music files to your device',
                  style: TextStyle(color: Colors.grey),
                ),
              ],
            ),
          );
        }

        return ListView.builder(
          padding: const EdgeInsets.all(12),
          itemCount: provider.songs.length,
          itemBuilder: (context, index) {
            final song = provider.songs[index];
            final isCurrentSong = provider.currentSong?.id == song.id;
            final isPlaying = isCurrentSong && provider.isPlaying;

            return Container(
              margin: const EdgeInsets.only(bottom: 10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(15),
                color: Theme.of(context).cardColor,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.05),
                    blurRadius: 5,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => FullPlayerScreen(song: song),
                      ),
                    );
                  },
                  borderRadius: BorderRadius.circular(15),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        // Album Art Placeholder
                        Container(
                          width: 50,
                          height: 50,
                          decoration: BoxDecoration(
                            gradient: isCurrentSong
                                ? const LinearGradient(
                                colors: [Colors.deepPurple, Colors.purple])
                                : LinearGradient(colors: [
                              Colors.deepPurple.shade300,
                              Colors.purple.shade300
                            ]),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Center(
                            child: isPlaying
                                ? const Icon(Icons.equalizer,
                                color: Colors.white, size: 24)
                                : Icon(Icons.music_note,
                                color: Colors.white.withOpacity(0.8), size: 24),
                          ),
                        ),
                        const SizedBox(width: 12),

                        // Song Info
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                song.name,
                                style: TextStyle(
                                  fontWeight: isCurrentSong
                                      ? FontWeight.bold
                                      : FontWeight.w600,
                                  fontSize: 14,
                                  color: isCurrentSong ? Colors.deepPurple : null,
                                ),
                                overflow: TextOverflow.ellipsis,
                                maxLines: 1,
                              ),
                              const SizedBox(height: 4),
                              Row(
                                children: [
                                  Icon(Icons.person_outline,
                                      size: 11, color: Colors.grey.shade600),
                                  const SizedBox(width: 4),
                                  Expanded(
                                    child: Text(
                                      song.artist,
                                      style: TextStyle(
                                          fontSize: 11, color: Colors.grey.shade600),
                                      overflow: TextOverflow.ellipsis,
                                      maxLines: 1,
                                    ),
                                  ),
                                ],
                              ),
                              if (isCurrentSong &&
                                  provider.totalDuration.inSeconds > 0)
                                Padding(
                                  padding: const EdgeInsets.only(top: 6),
                                  child: LinearProgressIndicator(
                                    value: provider.progress,
                                    backgroundColor: Colors.grey.shade200,
                                    valueColor:
                                    const AlwaysStoppedAnimation<Color>(
                                        Colors.deepPurple),
                                    minHeight: 2,
                                  ),
                                ),
                            ],
                          ),
                        ),

                        // Favorite Button
                        SizedBox(
                          width: 36,
                          child: IconButton(
                            icon: Icon(
                              song.isFavorite
                                  ? Icons.favorite
                                  : Icons.favorite_border,
                              color: song.isFavorite ? Colors.red : Colors.grey,
                              size: 20,
                            ),
                            onPressed: () => provider.toggleFavorite(song),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                          ),
                        ),

                        const SizedBox(width: 4),

                        // Play/Pause Button
                        Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: isCurrentSong && provider.isPlaying
                                ? Colors.deepPurple
                                : Colors.deepPurple.withOpacity(0.1),
                          ),
                          child: IconButton(
                            icon: Icon(
                              isCurrentSong && provider.isPlaying
                                  ? Icons.pause
                                  : Icons.play_arrow,
                              color: isCurrentSong && provider.isPlaying
                                  ? Colors.white
                                  : Colors.deepPurple,
                              size: 18,
                            ),
                            onPressed: () => provider.playSong(song),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                          ),
                        ),
                      ],
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

// ==================== FULL PLAYER SCREEN ====================
class FullPlayerScreen extends StatefulWidget {
  final Song song;

  const FullPlayerScreen({super.key, required this.song});

  @override
  State<FullPlayerScreen> createState() => _FullPlayerScreenState();
}

class _FullPlayerScreenState extends State<FullPlayerScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 500),
      vsync: this,
    );

    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeIn),
    );

    _scaleAnimation = Tween<double>(begin: 0.8, end: 1.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeOutBack),
    );

    _animationController.forward();

    final provider = Provider.of<AudioProvider>(context, listen: false);
    if (provider.currentSong?.id != widget.song.id) {
      provider.playSong(widget.song);
    }
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  String formatDuration(Duration duration) {
    if (duration.inSeconds <= 0) return '0:00';
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds.remainder(60);
    return "$minutes:${twoDigits(seconds)}";
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.deepPurple,
      body: Consumer<AudioProvider>(
        builder: (context, provider, child) {
          final isCurrentSong = provider.currentSong?.id == widget.song.id;
          final currentPosition =
          isCurrentSong ? provider.currentPosition : Duration.zero;
          final totalDuration =
          isCurrentSong ? provider.totalDuration : Duration.zero;
          final isPlaying = isCurrentSong && provider.isPlaying;

          return Stack(
            children: [
              // Background gradient
              Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.deepPurple,
                      Colors.deepPurpleAccent,
                      Colors.purple
                    ],
                  ),
                ),
              ),

              // Main content
              SafeArea(
                child: FadeTransition(
                  opacity: _fadeAnimation,
                  child: Column(
                    children: [
                      // App bar
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.arrow_back,
                                  color: Colors.white, size: 28),
                              onPressed: () => Navigator.pop(context),
                            ),
                            Text(
                              'Now Playing',
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.9),
                                fontSize: 18,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            IconButton(
                              icon: Icon(
                                widget.song.isFavorite
                                    ? Icons.favorite
                                    : Icons.favorite_border,
                                color: widget.song.isFavorite
                                    ? Colors.red
                                    : Colors.white,
                                size: 28,
                              ),
                              onPressed: () =>
                                  provider.toggleFavorite(widget.song),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 20),

                      // Album art with animation
                      ScaleTransition(
                        scale: _scaleAnimation,
                        child: Container(
                          width: MediaQuery.of(context).size.width * 0.7,
                          height: MediaQuery.of(context).size.width * 0.7,
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              colors: [Colors.white, Colors.white70],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                            borderRadius: BorderRadius.circular(30),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.3),
                                blurRadius: 30,
                                offset: const Offset(0, 15),
                              ),
                            ],
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(30),
                            child: Container(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  colors: [
                                    Colors.deepPurple.shade100,
                                    Colors.purple.shade100
                                  ],
                                ),
                              ),
                              child: Center(
                                child: Icon(
                                  Icons.music_note,
                                  size: 120,
                                  color: Colors.deepPurple.withOpacity(0.7),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),

                      const SizedBox(height: 40),

                      // Song info
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 32),
                        child: Column(
                          children: [
                            Text(
                              widget.song.name,
                              style: const TextStyle(
                                fontSize: 26,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                              textAlign: TextAlign.center,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              widget.song.artist,
                              style: TextStyle(
                                fontSize: 18,
                                color: Colors.white.withOpacity(0.8),
                              ),
                              textAlign: TextAlign.center,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 40),

                      // Seek bar
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 30),
                        child: Row(
                          children: [
                            Text(
                              formatDuration(currentPosition),
                              style: const TextStyle(
                                  fontSize: 12, color: Colors.white70),
                            ),
                            Expanded(
                              child: Slider(
                                value: totalDuration.inSeconds > 0
                                    ? currentPosition.inSeconds /
                                    totalDuration.inSeconds
                                    : 0.0,
                                onChanged: (value) {
                                  final position = totalDuration * value;
                                  provider.seekTo(position);
                                },
                                activeColor: Colors.white,
                                inactiveColor: Colors.white30,
                              ),
                            ),
                            Text(
                              formatDuration(totalDuration),
                              style: const TextStyle(
                                  fontSize: 12, color: Colors.white70),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 20),

                      // Control buttons
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            // Shuffle button
                            IconButton(
                              icon: Icon(
                                provider.isShuffle
                                    ? Icons.shuffle
                                    : Icons.shuffle_outlined,
                                color: provider.isShuffle
                                    ? Colors.white
                                    : Colors.white70,
                                size: 28,
                              ),
                              onPressed: provider.toggleShuffle,
                            ),

                            const SizedBox(width: 20),

                            // Previous button
                            Container(
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: Colors.white.withOpacity(0.1),
                              ),
                              child: IconButton(
                                icon: const Icon(Icons.skip_previous,
                                    color: Colors.white, size: 40),
                                onPressed: () => provider.previousSong(),
                              ),
                            ),

                            const SizedBox(width: 30),

                            // Play/Pause button
                            Container(
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: Colors.white,
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withOpacity(0.2),
                                    blurRadius: 15,
                                    offset: const Offset(0, 5),
                                  ),
                                ],
                              ),
                              child: IconButton(
                                icon: Icon(
                                  isPlaying ? Icons.pause : Icons.play_arrow,
                                  color: Colors.deepPurple,
                                  size: 50,
                                ),
                                onPressed: () {
                                  if (isCurrentSong) {
                                    provider.togglePlayPause();
                                  } else {
                                    provider.playSong(widget.song);
                                  }
                                },
                              ),
                            ),

                            const SizedBox(width: 30),

                            // Next button
                            Container(
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: Colors.white.withOpacity(0.1),
                              ),
                              child: IconButton(
                                icon: const Icon(Icons.skip_next,
                                    color: Colors.white, size: 40),
                                onPressed: () => provider.nextSong(),
                              ),
                            ),

                            const SizedBox(width: 20),

                            // Repeat button
                            IconButton(
                              icon: Icon(
                                provider.repeatMode == RepeatMode.one
                                    ? Icons.repeat_one
                                    : provider.repeatMode == RepeatMode.all
                                    ? Icons.repeat
                                    : Icons.repeat_outlined,
                                color: provider.repeatMode != RepeatMode.none
                                    ? Colors.white
                                    : Colors.white70,
                                size: 28,
                              ),
                              onPressed: provider.toggleRepeatMode,
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 30),

                      // Audio visualizer (animated bars)
                      if (isPlaying) _buildAudioVisualizer(),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildAudioVisualizer() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(5, (index) {
        return AnimatedContainer(
          duration: Duration(milliseconds: 500 + (index * 100)),
          margin: const EdgeInsets.symmetric(horizontal: 3),
          width: 4,
          height: 20 + (index * 5).toDouble(),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.7),
            borderRadius: BorderRadius.circular(2),
          ),
        );
      }),
    );
  }
}

// ==================== MINI PLAYER ====================
class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});

  String formatDuration(Duration duration) {
    if (duration.inSeconds <= 0) return '0:00';
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds.remainder(60);
    return "$minutes:${twoDigits(seconds)}";
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AudioProvider>(
      builder: (context, provider, child) {
        if (provider.currentSong == null) {
          return const SizedBox.shrink();
        }

        return GestureDetector(
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) =>
                    FullPlayerScreen(song: provider.currentSong!),
              ),
            );
          },
          child: Container(
            decoration: BoxDecoration(
              color: Theme.of(context).cardColor,
              boxShadow: [
                BoxShadow(
                    color: Colors.black.withOpacity(0.1),
                    blurRadius: 10,
                    offset: const Offset(0, -2)),
              ],
            ),
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Seek bar
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      children: [
                        Text(
                          formatDuration(provider.currentPosition),
                          style:
                          const TextStyle(fontSize: 11, color: Colors.grey),
                        ),
                        Expanded(
                          child: Slider(
                            value: provider.progress,
                            onChanged: (value) {
                              final position = provider.totalDuration * value;
                              provider.seekTo(position);
                            },
                            activeColor: Colors.deepPurple,
                            inactiveColor: Colors.grey.shade300,
                          ),
                        ),
                        Text(
                          formatDuration(provider.totalDuration),
                          style:
                          const TextStyle(fontSize: 11, color: Colors.grey),
                        ),
                      ],
                    ),
                  ),

                  Padding(
                    padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Row(
                      children: [
                        // Album Art
                        Container(
                          width: 45,
                          height: 45,
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                                colors: [Colors.deepPurple, Colors.purple]),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Center(
                            child: Icon(Icons.music_note,
                                color: Colors.white, size: 24),
                          ),
                        ),
                        const SizedBox(width: 12),

                        // Song Info
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                provider.currentSong!.name,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14,
                                ),
                                overflow: TextOverflow.ellipsis,
                                maxLines: 1,
                              ),
                              Text(
                                provider.currentSong!.artist,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey.shade600,
                                ),
                                overflow: TextOverflow.ellipsis,
                                maxLines: 1,
                              ),
                            ],
                          ),
                        ),

                        // Control Buttons
                        IconButton(
                          icon: const Icon(Icons.skip_previous, size: 28),
                          onPressed: () => provider.previousSong(),
                        ),

                        Container(
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.deepPurple,
                          ),
                          child: IconButton(
                            icon: Icon(
                              provider.isPlaying ? Icons.pause : Icons.play_arrow,
                              color: Colors.white,
                              size: 28,
                            ),
                            onPressed: provider.togglePlayPause,
                          ),
                        ),

                        IconButton(
                          icon: const Icon(Icons.skip_next, size: 28),
                          onPressed: () => provider.nextSong(),
                        ),
                      ],
                    ),
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