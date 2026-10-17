import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';
import 'package:device_info_plus/device_info_plus.dart'; // <-- ADDED

void main() {
  runApp(const WinChatApp());
}

// Business Endpoint constants
const String API_URL = "https://winnersonlineschool.com/API/winners_api.php"; // Update this to your actual PHP file name if different
const String RECEIVER = "SCH001";
const int MAX_FILE_SIZE_MB = 100;

class WinChatApp extends StatelessWidget {
  const WinChatApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'WinChat',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        scaffoldBackgroundColor: Colors.white,
        primarySwatch: Colors.blueGrey,
        useMaterial3: true,
        appBarTheme: const AppBarTheme(
          systemOverlayStyle: SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness: Brightness.dark,
            statusBarBrightness: Brightness.light,
          ),
        ),
      ),
      home: const HomePage(),
    );
  }
}

// ---------- Data Models ----------
class ScreenRecord {
  final String id;
  final String? parentId;
  final String? folder;
  final String? folderName;
  final String message;
  final String type;
  final Map<String, dynamic>? content;
  final String timestamp;
  final int updatedAt;

  ScreenRecord({
    required this.id,
    required this.parentId,
    required this.folder,
    required this.folderName,
    required this.message,
    required this.type,
    required this.content,
    required this.timestamp,
    required this.updatedAt,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'parentId': parentId,
        'folder': folder,
        'folderName': folderName,
        'message': message,
        'type': type,
        'content': content != null ? jsonEncode(content) : null,
        'timestamp': timestamp,
        'updatedAt': updatedAt,
      };

  factory ScreenRecord.fromMap(Map<String, dynamic> map) => ScreenRecord(
        id: map['id'] as String,
        parentId: map['parentId'] as String?,
        folder: map['folder'] as String?,
        folderName: map['folderName'] as String?,
        message: map['message'] as String? ?? "",
        type: map['type'] as String? ?? "text",
        content: map['content'] != null
            ? jsonDecode(map['content'] as String)
            : null,
        timestamp: map['timestamp'] as String? ?? "",
        updatedAt: map['updatedAt'] as int? ?? 0,
      );
}

class NavigationItem {
  final String id;
  final String name;
  final String? parentId;

  NavigationItem({required this.id, required this.name, required this.parentId});
}

// ---------- Database Helper ----------
class DatabaseHelper {
  static Database? _database;

  static Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB();
    return _database!;
  }

  static Future<Database> _initDB() async {
    final String path = join(await getDatabasesPath(), 'winchat.db');
    return openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE screens(
            id TEXT PRIMARY KEY,
            parentId TEXT,
            folder TEXT,
            folderName TEXT,
            message TEXT,
            type TEXT,
            content TEXT,
            timestamp TEXT,
            updatedAt INTEGER
          )
        ''');
        await db.execute('''
          CREATE INDEX idx_parentId
          ON screens(parentId)
        ''');
      },
    );
  }

  static Future<void> saveScreen(ScreenRecord record) async {
    final db = await database;
    await db.insert(
      'screens',
      record.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static Future<ScreenRecord?> getScreen(String id) async {
    final db = await database;
    final result = await db.query(
      'screens',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (result.isEmpty) {
      return null;
    }
    return ScreenRecord.fromMap(result.first);
  }

  static Future<List<ScreenRecord>> getChildren(String? parentId) async {
    final db = await database;
    late List<Map<String, dynamic>> result;
    if (parentId == null) {
      result = await db.query(
        'screens',
        where: 'parentId IS NULL',
        orderBy: 'updatedAt DESC',
      );
    } else {
      result = await db.query(
        'screens',
        where: 'parentId = ?',
        whereArgs: [parentId],
        orderBy: 'updatedAt DESC',
      );
    }
    return result.map((row) => ScreenRecord.fromMap(row)).toList();
  }
}

// ---------- File Download Manager ----------
class FileDownloadManager {
  static String? _downloadDir;

  static Future<String> getDownloadDir() async {
    if (_downloadDir != null) {
      return _downloadDir!;
    }
    final directory = await getApplicationDocumentsDirectory();
    _downloadDir = directory.path;
    return _downloadDir!;
  }

  static Future<String?> getLocalPath(String filename) async {
    final dir = await getDownloadDir();
    final path = join(dir, filename);
    if (await File(path).exists()) {
      return path;
    }
    return null;
  }

  static Future<void> downloadFile(
    String url,
    String filename, {
    required void Function(double progress) onProgress,
    required void Function(String error) onError,
    int maxRetries = 3,
  }) async {
    final dir = await getDownloadDir();
    final savePath = join(dir, filename);
    
    int attempts = 0;
    while (attempts < maxRetries) {
      try {
        attempts++;
        
        final client = HttpClient();
        client.connectionTimeout = const Duration(seconds: 60);
        client.idleTimeout = const Duration(seconds: 60);
        
        try {
          final request = await client.getUrl(Uri.parse(url));
          request.headers.add('User-Agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36');
          request.headers.add('Accept', '*/*');
          request.headers.add('Connection', 'keep-alive');
          
          final response = await request.close();
          
          if (response.statusCode != 200) {
            throw Exception('HTTP Error ${response.statusCode}');
          }
          
          final contentLength = response.contentLength;
          final file = File(savePath);
          final sink = file.openWrite();
          
          int received = 0;
          await for (final chunk in response) {
            sink.add(chunk);
            received += chunk.length;
            
            if (contentLength > 0) {
              onProgress(received / contentLength);
            }
          }
          
          await sink.flush();
          await sink.close();
          
          if (contentLength > 0 && received < contentLength) {
            throw Exception('Incomplete download');
          }
          
          client.close();
          return;
          
        } catch (e) {
          client.close();
          rethrow;
        }
      } catch (e) {
        if (attempts >= maxRetries) {
          try {
            final file = File(savePath);
            if (await file.exists()) {
              await file.delete();
            }
          } catch (_) {}
          onError(e.toString());
          rethrow;
        }
        await Future.delayed(Duration(seconds: attempts * 2));
      }
    }
  }

  static Future<String> getFileNameFromUrl(String url) async {
    try {
      final uri = Uri.parse(url);
      if (uri.pathSegments.isNotEmpty) {
        final filename = uri.pathSegments.last;
        if (filename.isNotEmpty) {
          String cleanFilename = filename.split('?').first;
          return cleanFilename.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
        }
      }
    } catch (_) {}
    return 'file_${DateTime.now().millisecondsSinceEpoch}';
  }
}

// ---------- Main Stateful Widget ----------
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<Widget> _chatMessages = [];
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  List<NavigationItem> _navigationPath = [];
  bool _isSending = false;
  bool _isWaitingForPhone = false;
  bool _isEditingAccount = false;
  String _currentPhone = "";
  bool _isLoading = false;
  
  // Device ID variable
  String _deviceId = "";

  @override
  void initState() {
    super.initState();
    _initializeApp();
  }

  @override
  void dispose() {
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _initializeApp() async {
    await _initDatabase();
    await FileDownloadManager.getDownloadDir();
    
    // Generate Device ID
    final DeviceInfoPlugin deviceInfo = DeviceInfoPlugin();
    try {
      if (Platform.isAndroid) {
        final androidInfo = await deviceInfo.androidInfo;
        _deviceId = androidInfo.id; 
      } else if (Platform.isIOS) {
        final iosInfo = await deviceInfo.iosInfo;
        _deviceId = iosInfo.identifierForVendor ?? "unknown_ios";
      } else {
        _deviceId = "unknown_device";
      }
    } catch (e) {
      debugPrint("Error getting device ID: $e");
      _deviceId = "error_device";
    }
    debugPrint("DEVICE ID: $_deviceId");

    _currentPhone = await _getSender() ?? "";

    if (_currentPhone.isEmpty) {
      if (!mounted) return;
      setState(() {
        _isWaitingForPhone = true;
        _chatMessages = [
          _buildServerBubble("Please enter your phone number to continue:"),
        ];
      });
      return;
    }

    await _loadCachedHome();

    try {
      await _requestServer("HOME", null);
    } catch (e) {
      debugPrint("Server unavailable, using cached data: $e");
    }
  }

  Future<void> _initDatabase() async {
    await DatabaseHelper.database;
  }

  Future<String?> _getSender() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    return prefs.getString('winchat_sender');
  }

  Future<void> _setSender(String phone) async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString('winchat_sender', phone);
    _currentPhone = phone;
  }

  Future<void> _loadCachedHome() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    String? homeId = prefs.getString('winchat_home_screen');
    
    ScreenRecord? home;
    if (homeId != null) {
      home = await DatabaseHelper.getScreen(homeId);
    }
    
    if (home == null) {
      var roots = await DatabaseHelper.getChildren(null);
      if (roots.isEmpty) return;
      roots.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      home = roots.first;
    }

    if (home == null || !mounted) return;

    final cachedHome = home!;

    setState(() {
      _navigationPath = [
        NavigationItem(
          id: cachedHome.id,
          name: cachedHome.folderName ?? cachedHome.id,
          parentId: null
        )
      ];
      _chatMessages = _parseAndRenderServerMessage(
        message: cachedHome.message,
        type: cachedHome.type,
        content: cachedHome.content,
        title: cachedHome.folderName ?? cachedHome.id,
        screenId: cachedHome.id
      );
    });
  }

  Future<void> _requestServer(String id, String? parentId) async {
    if (_isSending) return;

    setState(() {
      _isSending = true;
      _isLoading = true;
    });

    try {
      String sender = _currentPhone;
      if (sender.isEmpty) throw Exception("Phone number required");

      Map<String, dynamic> payload = {
        "sender": sender,
        "receiver": RECEIVER,
        "message": id,
        "parent_id": parentId,
        "device_id": _deviceId, // <-- SENDING DEVICE ID HERE
      };

      final response = await http.post(
        Uri.parse(API_URL),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode(payload),
      ).timeout(const Duration(seconds: 15));

      Map<String, dynamic> data = jsonDecode(utf8.decode(response.bodyBytes));

      setState(() => _isLoading = false);

      if (data["success"] != true) {
        _addErrorMessage(data["message"] ?? "Server error");
        setState(() => _isSending = false);
        return;
      }

      bool shouldSave = data["save"] != false;
      String screenId = data["screen_id"]?.toString() ?? id;
      if (screenId.isEmpty) screenId = DateTime.now().millisecondsSinceEpoch.toString();

      if (id == "HOME" && screenId.isNotEmpty) {
        SharedPreferences prefs = await SharedPreferences.getInstance();
        await prefs.setString('winchat_home_screen', screenId);
      }

      String? apiParentId = data["parent_id"]?.toString();
      String? actualParentId;

      if (apiParentId == screenId) {
        actualParentId = parentId;
      } else if (apiParentId == null && parentId != null) {
        actualParentId = parentId;
      } else {
        actualParentId = apiParentId;

        if (actualParentId != null && parentId != null && actualParentId != parentId) {
          final apiParentInCache = await DatabaseHelper.getScreen(actualParentId);
          final requestParentInCache = await DatabaseHelper.getScreen(parentId);
          if (apiParentInCache == null && requestParentInCache != null) {
            actualParentId = parentId;
          }
        }
      }

      if (shouldSave) {
        ScreenRecord record = ScreenRecord(
          id: screenId,
          parentId: actualParentId,
          folder: data["folder"]?.toString(),
          folderName: data["folder_name"]?.toString() ?? data["screen_id"]?.toString(),
          message: data["message"]?.toString() ?? "",
          type: data["type"]?.toString() ?? "text",
          content: data["content"] is Map
              ? Map<String, dynamic>.from(data["content"])
              : null,
          timestamp: data["timestamp"]?.toString() ?? DateTime.now().toIso8601String(),
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        );

        await DatabaseHelper.saveScreen(record);
      }

      List<NavigationItem> parentPath = [];
      if (parentId != null) {
        parentPath = await _buildPathFromCache(parentId);
      }
      parentPath.add(NavigationItem(
        id: screenId,
        name: data["folder_name"]?.toString() ?? screenId,
        parentId: actualParentId,
      ));

      if (!mounted) return;
      setState(() {
        _navigationPath = parentPath;
        _chatMessages = _parseAndRenderServerMessage(
          message: data["message"]?.toString() ?? "",
          type: data["type"]?.toString() ?? "text",
          content: data["content"] is Map
              ? Map<String, dynamic>.from(data["content"])
              : null,
          title: data["folder_name"]?.toString() ?? screenId,
          screenId: screenId
        );
      });

    } catch (e) {
      setState(() => _isLoading = false);
      debugPrint("FULL ERROR: $e");

      ScreenRecord? cached = await DatabaseHelper.getScreen(id);
      if (cached != null) {
        final nonNullCached = cached;
        _navigationPath = await _buildPathFromCache(id);
        if (_navigationPath.isEmpty) {
          _navigationPath = [
            NavigationItem(
                id: id, name: nonNullCached.folderName ?? id, parentId: nonNullCached.parentId)
          ];
        }
        if (!mounted) return;
        setState(() {
          _chatMessages = _parseAndRenderServerMessage(
            message: nonNullCached.message,
            type: nonNullCached.type,
            content: nonNullCached.content,
            title: nonNullCached.folderName ?? id,
            screenId: id
          );
        });
      } else {
        _addErrorMessage("Server request failed: $e");
      }
    } finally {
      if (mounted) {
        setState(() => _isSending = false);
      }
    }
  }

  Future<void> _navigateLocal(String id) async {
    id = id.toString();
    debugPrint("LOCAL NAVIGATION: $id");

    ScreenRecord? cached = await DatabaseHelper.getScreen(id);
    if (cached == null) {
      _addErrorMessage("This item has not been cached yet.");
      return;
    }

    ScreenRecord finalCached = ScreenRecord(
      id: cached.id,
      parentId: cached.parentId,
      folder: cached.folder,
      folderName: cached.folderName,
      message: cached.message,
      type: cached.type,
      content: cached.content,
      timestamp: cached.timestamp,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await DatabaseHelper.saveScreen(finalCached);

    _navigationPath = await _buildPathFromCache(id);

    if (!mounted) return;
    setState(() {
      _chatMessages = _parseAndRenderServerMessage(
        message: finalCached.message,
        type: finalCached.type,
        content: finalCached.content,
        title: finalCached.folderName ?? id,
        screenId: id
      );
    });
    _scrollToBottom();
  }

  Future<List<NavigationItem>> _buildPathFromCache(String currentId) async {
    List<NavigationItem> reversed = [];
    Set<String> visited = {};
    ScreenRecord? current = await DatabaseHelper.getScreen(currentId);

    while (current != null && !visited.contains(current.id)) {
      visited.add(current.id);
      reversed.add(NavigationItem(
        id: current.id,
        name: current.folderName ?? current.id,
        parentId: current.parentId,
      ));

      if (current.parentId == null) break;
      current = await DatabaseHelper.getScreen(current.parentId!);
    }

    return reversed.reversed.toList();
  }

  void _showAccountMenu() {
    setState(() {
      _isEditingAccount = true;
      _chatMessages = [
        ..._chatMessages,
        _buildServerBubble(
            "Account Settings\n\nCurrent Phone: ${_currentPhone.isEmpty ? 'Not set' : _currentPhone}\n\n"
            "1. Update Phone Number\n"
            "2. View Current Number\n"
            "3. Cancel")
      ];
    });
    _scrollToBottom();
  }

  void _handleAccountMenuSelection(String message) {
    if (message == "1") {
      setState(() {
        _chatMessages = [
          ..._chatMessages,
          _buildServerBubble("Please type your new phone number (e.g., 265999999999):")
        ];
        _isEditingAccount = false;
        _isWaitingForPhone = true;
      });
    } else if (message == "2") {
      _addServerMessage(
          "Your current phone number is: ${_currentPhone.isEmpty ? 'Not set' : _currentPhone}");
      setState(() => _isEditingAccount = false);
    } else if (message == "3") {
      _addServerMessage("Account settings closed.");
      setState(() => _isEditingAccount = false);
    } else {
      _addErrorMessage("Invalid option. Please type 1, 2, or 3.");
    }
    _scrollToBottom();
  }

  List<Widget> _parseAndRenderServerMessage({
    required String message,
    required String type,
    required Map<String, dynamic>? content,
    required String title,
    required String screenId,
  }) {
    List<Widget> widgets = [];
    
    if (type == "video" && content != null && content['url'] != null) {
      widgets.add(_buildVideoBubble(content['url'].toString(), title));
      return widgets;
    } else if (type == "pdf" && content != null && content['url'] != null) {
      widgets.add(_buildPdfDownloadBubble(content['url'].toString(), title));
      return widgets;
    } else if (type == "image" && content != null && content['url'] != null) {
      widgets.add(_buildImageDownloadBubble(content['url'].toString(), title));
      return widgets;
    }
    
    List<String> lines = message.split('\n');
    List<String> urls = [];
    List<String> textLines = [];

    RegExp urlRegex = RegExp(r'https?://[^\s]+');
    for (String line in lines) {
      Iterable<RegExpMatch> matches = urlRegex.allMatches(line);
      if (matches.isNotEmpty) {
        for (var match in matches) {
          urls.add(match.group(0)!);
        }
        String cleaned = line.replaceAll(urlRegex, '').trim();
        if (cleaned.isNotEmpty) {
          textLines.add(cleaned);
        }
      } else {
        textLines.add(line);
      }
    }

    String header = textLines.join('\n').trim();
    if (header.isNotEmpty) {
      widgets.add(_buildTextBubble(header));
    }

    for (String url in urls) {
      Uri? uri = Uri.tryParse(url);
      String path = uri?.path.toLowerCase() ?? '';
      
      if (path.endsWith('.mp4') || path.contains('video')) {
        widgets.add(_buildVideoBubble(url, title));
      } else if (path.endsWith('.pdf')) {
        widgets.add(_buildPdfDownloadBubble(url, title));
      } else if (path.endsWith('.jpg') || path.endsWith('.jpeg') || 
                 path.endsWith('.png') || path.endsWith('.gif') || 
                 path.endsWith('.webp')) {
        widgets.add(_buildImageDownloadBubble(url, title));
      } else {
        widgets.add(_buildTextBubble(url));
      }
    }

    return widgets;
  }

  Widget _buildTextBubble(String text) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: const BoxDecoration(
          color: Color(0xFFF0F0F0),
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(17),
            topRight: Radius.circular(17),
            bottomRight: Radius.circular(17),
            bottomLeft: Radius.circular(5),
          ),
        ),
        child: Text(text),
      ),
    );
  }

  Widget _buildVideoBubble(String url, String title) {
    return FutureBuilder<String>(
      future: FileDownloadManager.getFileNameFromUrl(url),
      builder: (context, filenameSnapshot) {
        if (!filenameSnapshot.hasData) {
          return const SizedBox(height: 50, child: Center(child: CircularProgressIndicator()));
        }
        final filename = filenameSnapshot.data!;
        return FutureBuilder<String?>(
          future: FileDownloadManager.getLocalPath(filename),
          builder: (context, snapshot) {
            final isDownloaded = snapshot.hasData && snapshot.data != null;
            
            return Align(
              alignment: Alignment.centerLeft,
              child: Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(12),
                constraints: const BoxConstraints(maxWidth: 350),
                decoration: const BoxDecoration(
                  color: Color(0xFFF0F0F0),
                  borderRadius: BorderRadius.only(
                    topLeft: Radius.circular(17),
                    topRight: Radius.circular(17),
                    bottomRight: Radius.circular(17),
                    bottomLeft: Radius.circular(5),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 6),
                    if (isDownloaded)
                      _SocialVideoPlayer(filePath: snapshot.data!)
                    else
                      _VideoDownloadPlaceholder(
                        url: url,
                        filename: filename,
                        title: title,
                        onDownloadComplete: () {
                          setState(() {});
                        },
                      ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildPdfDownloadBubble(String url, String title) {
    return FutureBuilder<String>(
      future: FileDownloadManager.getFileNameFromUrl(url),
      builder: (context, filenameSnapshot) {
        if (!filenameSnapshot.hasData) {
          return const SizedBox(height: 50, child: Center(child: CircularProgressIndicator()));
        }
        final filename = filenameSnapshot.data!;
        return FutureBuilder<String?>(
          future: FileDownloadManager.getLocalPath(filename),
          builder: (context, snapshot) {
            if (snapshot.hasData && snapshot.data != null) {
              return _buildLocalPdfButton(snapshot.data!, title);
            }
            return _buildDownloadButton(url, title, isPdf: true);
          },
        );
      },
    );
  }

  Widget _buildImageDownloadBubble(String url, String title) {
    return FutureBuilder<String>(
      future: FileDownloadManager.getFileNameFromUrl(url),
      builder: (context, filenameSnapshot) {
        if (!filenameSnapshot.hasData) {
          return const SizedBox(height: 50, child: Center(child: CircularProgressIndicator()));
        }
        final filename = filenameSnapshot.data!;
        return FutureBuilder<String?>(
          future: FileDownloadManager.getLocalPath(filename),
          builder: (context, snapshot) {
            if (snapshot.hasData && snapshot.data != null) {
              return _buildLocalImage(snapshot.data!);
            }
            return _buildDownloadButton(url, title, isImage: true);
          },
        );
      },
    );
  }

  Widget _buildDownloadButton(
    String url,
    String title, {
    bool isVideo = false,
    bool isPdf = false,
    bool isImage = false,
  }) {
    return StatefulBuilder(
      builder: (context, setState) {
        double progress = 0.0;
        bool isDownloading = false;
        String? error;
        
        return Align(
          alignment: Alignment.centerLeft,
          child: Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(12),
            constraints: const BoxConstraints(maxWidth: 300),
            decoration: const BoxDecoration(
              color: Color(0xFFF0F0F0),
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(17),
                topRight: Radius.circular(17),
                bottomRight: Radius.circular(17),
                bottomLeft: Radius.circular(5),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 6),
                if (isDownloading)
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      LinearProgressIndicator(value: progress),
                      const SizedBox(height: 4),
                      Text(
                        "Downloading: ${(progress * 100).toStringAsFixed(0)}%",
                        style: const TextStyle(fontSize: 12),
                      ),
                    ],
                  )
                else if (error != null)
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '⚠️ $error',
                        style: TextStyle(
                          color: Colors.red.shade700,
                          fontSize: 12,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 4),
                      ElevatedButton(
                        onPressed: () {
                          setState(() {
                            error = null;
                            isDownloading = true;
                            progress = 0;
                          });
                          _retryDownload(url, setState);
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.black,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                          minimumSize: const Size(0, 28),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          textStyle: const TextStyle(fontSize: 12),
                        ),
                        child: const Text('Retry'),
                      ),
                    ],
                  )
                else
                  SizedBox(
                    height: 32,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          isVideo ? Icons.videocam : isPdf ? Icons.picture_as_pdf : isImage ? Icons.image : Icons.music_note,
                          size: 18,
                          color: Colors.grey.shade700,
                        ),
                        const SizedBox(width: 6),
                        ElevatedButton(
                          onPressed: () {
                            _retryDownload(url, setState);
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.black,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                            minimumSize: const Size(0, 28),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            textStyle: const TextStyle(fontSize: 13),
                          ),
                          child: Text(
                            isVideo ? "Download Video" : isPdf ? "Download PDF" : isImage ? "Download Image" : "Download"
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _retryDownload(String url, StateSetter setState) async {
    try {
      final fileName = await FileDownloadManager.getFileNameFromUrl(url);
      await FileDownloadManager.downloadFile(
        url, 
        fileName,
        onProgress: (p) {
          if (mounted) {
            setState(() {});
          }
        },
        onError: (error) {
          if (mounted) {
            _addErrorMessage('Download failed: ${error.replaceFirst('Exception: ', '')}');
          }
        },
      );
      if (mounted) {
        setState(() {});
        _addServerMessage('✅ Download complete!');
      }
    } catch (e) {
      if (mounted) {
        _addErrorMessage('Download failed: ${e.toString().replaceFirst('Exception: ', '')}');
      }
    }
  }

  Widget _buildLocalPdfButton(String localPath, String title) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        constraints: const BoxConstraints(maxWidth: 300),
        decoration: const BoxDecoration(
          color: Color(0xFFF0F0F0),
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(17),
            topRight: Radius.circular(17),
            bottomRight: Radius.circular(17),
            bottomLeft: Radius.circular(5),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 6),
            GestureDetector(
              onTap: () async {
                if (await canLaunchUrl(Uri.file(localPath))) {
                  await launchUrl(Uri.file(localPath));
                }
              },
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Text(
                  "Open PDF",
                  style: TextStyle(color: Colors.white, fontSize: 13),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLocalImage(String localPath) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        constraints: const BoxConstraints(maxWidth: 250),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(17),
          child: Image.file(
            File(localPath),
            width: 250,
            fit: BoxFit.cover,
          ),
        ),
      ),
    );
  }

  void _addServerMessage(String text) {
    setState(() {
      _chatMessages = [..._chatMessages, _buildTextBubble(text)];
    });
    _scrollToBottom();
  }

  void _addErrorMessage(String text) {
    setState(() {
      _chatMessages = [
        ..._chatMessages,
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 5),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.red.shade50,
            borderRadius: BorderRadius.circular(15),
          ),
          child: Text(
            text, 
            style: const TextStyle(color: Colors.red, fontSize: 12),
          ),
        )
      ];
    });
    _scrollToBottom();
  }

  Widget _buildLoadingBubble() {
    return const Padding(
      padding: EdgeInsets.all(10),
      child: Text("Loading...", style: TextStyle(color: Colors.grey)),
    );
  }

  Widget _buildServerBubble(String text) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: const BoxDecoration(
          color: Color(0xFFF0F0F0),
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(17),
            topRight: Radius.circular(17),
            bottomRight: Radius.circular(17),
            bottomLeft: Radius.circular(5),
          ),
        ),
        child: Text(text),
      ),
    );
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _sendMessage() async {
    String msg = _inputController.text.trim();
    if (msg.isEmpty) return;
    _inputController.clear();

    if (msg == "#123#") {
      _showAccountMenu();
      return;
    }

    if (_isEditingAccount) {
      _handleAccountMenuSelection(msg);
      return;
    }

    if (_isWaitingForPhone) {
      if (msg.length < 10) {
        _addErrorMessage("Invalid phone number. Please enter a valid number (e.g., 265999999999).");
        return;
      }
      await _setSender(msg);
      if (!mounted) return;
      setState(() {
        _isWaitingForPhone = false;
        _chatMessages = [];
      });
      await _requestServer("HOME", null);
      return;
    }

    setState(() {
      _chatMessages = [
        ..._chatMessages,
        Align(
          alignment: Alignment.centerRight,
          child: Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: const BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(17),
                topRight: Radius.circular(17),
                bottomLeft: Radius.circular(17),
                bottomRight: Radius.circular(5),
              ),
            ),
            child: Text(msg, style: const TextStyle(color: Colors.white)),
          ),
        )
      ];
    });

    String? parentId = _navigationPath.isNotEmpty ? _navigationPath.last.id : null;
    await _requestServer(msg, parentId);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Container(
              height: 48,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: Color(0xFFE5E5E5))),
              ),
              child: Row(
                children: [
                  const Text("WinChat", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17)),
                  const Spacer(),
                  const Text("Online", style: TextStyle(color: Colors.grey, fontSize: 11)),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                controller: _scrollController,
                padding: const EdgeInsets.fromLTRB(14, 18, 14, 20),
                children: [
                  ..._chatMessages,
                  if (_isLoading) _buildLoadingBubble(),
                ],
              ),
            ),
            Container(
              color: Colors.white,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    height: 36,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: [
                        ..._navigationPath.map((item) {
                          final bool isCurrent =
                              _navigationPath.isNotEmpty && item.id == _navigationPath.last.id;
                          return Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: GestureDetector(
                              onTap: () => _navigateLocal(item.id),
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(
                                  color: isCurrent ? Colors.black : const Color(0xFFF3F3F3),
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(color: Colors.grey.shade300, width: 0.5),
                                ),
                                child: Text(
                                  item.name,
                                  style: TextStyle(
                                    color: isCurrent ? Colors.white : Colors.black,
                                    fontSize: 11,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                          );
                        }),
                        ..._buildCachedChildrenBadges(),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _inputController,
                            decoration: InputDecoration(
                              hintText: "Type a message...",
                              filled: true,
                              fillColor: const Color(0xFFF7F7F7),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(21),
                                borderSide: BorderSide.none,
                              ),
                              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                              isDense: true,
                            ),
                            onSubmitted: (_) => _sendMessage(),
                          ),
                        ),
                        const SizedBox(width: 8),
                        GestureDetector(
                          onTap: _sendMessage,
                          child: Container(
                            width: 38,
                            height: 38,
                            decoration: const BoxDecoration(
                              color: Colors.black,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.arrow_upward, color: Colors.white, size: 20),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildCachedChildrenBadges() {
    if (_navigationPath.isEmpty) return [];

    String currentId = _navigationPath.last.id;
    return [
      FutureBuilder<List<ScreenRecord>>(
        future: DatabaseHelper.getChildren(currentId),
        builder: (context, snapshot) {
          if (!snapshot.hasData || snapshot.data!.isEmpty) {
            return const SizedBox.shrink();
          }
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: snapshot.data!.where((child) {
              return !_navigationPath.any((p) => p.id == child.id);
            }).map((child) {
              return Padding(
                padding: const EdgeInsets.only(right: 6),
                child: GestureDetector(
                  onTap: () => _navigateLocal(child.id),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF3F3F3),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: Colors.grey.shade300, width: 0.5),
                    ),
                    child: Text(
                      child.folderName ?? child.id,
                      style: const TextStyle(color: Colors.black, fontSize: 11),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              );
            }).toList(),
          );
        },
      ),
    ];
  }
}

// ---------- Video Download Placeholder ----------
class _VideoDownloadPlaceholder extends StatefulWidget {
  final String url;
  final String filename;
  final String title;
  final VoidCallback onDownloadComplete;

  const _VideoDownloadPlaceholder({
    super.key,
    required this.url,
    required this.filename,
    required this.title,
    required this.onDownloadComplete,
  });

  @override
  State<_VideoDownloadPlaceholder> createState() => _VideoDownloadPlaceholderState();
}

class _VideoDownloadPlaceholderState extends State<_VideoDownloadPlaceholder> {
  bool _isDownloading = false;
  double _progress = 0.0;
  String? _error;
  String? _errorDetails;

  Future<void> _startDownload() async {
    if (_isDownloading) return;
    
    setState(() {
      _isDownloading = true;
      _progress = 0.0;
      _error = null;
      _errorDetails = null;
    });

    try {
      await FileDownloadManager.downloadFile(
        widget.url,
        widget.filename,
        onProgress: (progress) {
          if (mounted) {
            setState(() {
              _progress = progress;
            });
          }
        },
        onError: (error) {
          if (mounted) {
            setState(() {
              _error = 'Download Failed';
              _errorDetails = error.replaceFirst('Exception: ', '');
              _isDownloading = false;
            });
          }
        },
      );
      
      if (mounted) {
        setState(() {
          _progress = 1.0;
        });
        await Future.delayed(const Duration(milliseconds: 300));
        if (mounted) {
          widget.onDownloadComplete();
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isDownloading = false;
          _error = 'Download Failed';
          _errorDetails = e.toString().replaceFirst('Exception: ', '');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    String errorDisplayDetails = _errorDetails ?? '';
    if (errorDisplayDetails.length > 80) {
      errorDisplayDetails = errorDisplayDetails.substring(0, 80) + '...';
    }

    if (_progress >= 1.0 && _isDownloading) {
      return Container(
        height: 200,
        decoration: BoxDecoration(
          color: Colors.black,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.green.shade800,
                    Colors.green.shade900,
                  ],
                ),
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 60,
                  height: 60,
                  decoration: BoxDecoration(
                    color: Colors.green.shade600,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.check,
                    color: Colors.white,
                    size: 32,
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Download Complete!',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Loading video...',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    }

    return GestureDetector(
      onTap: _startDownload,
      child: Container(
        height: 200,
        decoration: BoxDecoration(
          color: Colors.black,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.grey.shade800,
                    Colors.grey.shade900,
                  ],
                ),
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (_isDownloading) ...[
                  SizedBox(
                    width: 60,
                    height: 60,
                    child: CircularProgressIndicator(
                      value: _progress,
                      strokeWidth: 4,
                      valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '${(_progress * 100).toStringAsFixed(0)}%',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ] else if (_error != null) ...[
                  Container(
                    width: 60,
                    height: 60,
                    decoration: BoxDecoration(
                      color: Colors.red.shade800,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.error_outline,
                      color: Colors.white,
                      size: 32,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    errorDisplayDetails,
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 11,
                    ),
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Text(
                      'Tap to Retry',
                      style: TextStyle(
                        color: Colors.black,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ] else ...[
                  Container(
                    width: 60,
                    height: 60,
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.download,
                      color: Colors.black,
                      size: 32,
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Download Video',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ---------- Social Media Style Video Player (Simplified) ----------
class _SocialVideoPlayer extends StatefulWidget {
  final String filePath;
  const _SocialVideoPlayer({required this.filePath});

  @override
  State<_SocialVideoPlayer> createState() => _SocialVideoPlayerState();
}

class _SocialVideoPlayerState extends State<_SocialVideoPlayer> with WidgetsBindingObserver {
  late VideoPlayerController _controller;
  bool _isInitialized = false;
  bool _isPlaying = false;
  String? _error;
  bool _showControls = true;
  bool _isFullScreen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeVideo();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || 
        state == AppLifecycleState.inactive) {
      if (_isInitialized && _controller.value.isPlaying) {
        _controller.pause();
        setState(() {
          _isPlaying = false;
        });
      }
    }
  }

  Future<void> _initializeVideo() async {
    try {
      _controller = VideoPlayerController.file(File(widget.filePath));
      await _controller.initialize();
      if (!mounted) {
        _controller.dispose();
        return;
      }
      setState(() {
        _isInitialized = true;
      });
      
      await _controller.play();
      setState(() {
        _isPlaying = true;
      });
      
      Future.delayed(const Duration(seconds: 3), () {
        if (mounted && _controller.value.isPlaying) {
          setState(() {
            _showControls = false;
          });
        }
      });
      
      _controller.addListener(() {
        if (!mounted) return;
        final playing = _controller.value.isPlaying;
        if (playing != _isPlaying) {
          setState(() {
            _isPlaying = playing;
          });
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_isInitialized) {
      _controller.pause();
      _controller.dispose();
    }
    super.dispose();
  }

  void _togglePlay() {
    if (!_isInitialized) return;
    if (_controller.value.isPlaying) {
      _controller.pause();
      setState(() {
        _isPlaying = false;
      });
    } else {
      _controller.play();
      setState(() {
        _isPlaying = true;
      });
      Future.delayed(const Duration(seconds: 3), () {
        if (mounted && _controller.value.isPlaying) {
          setState(() {
            _showControls = false;
          });
        }
      });
    }
  }

  void _toggleFullScreen() async {
    setState(() {
      _isFullScreen = !_isFullScreen;
    });
    
    if (_isFullScreen) {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]);
    } else {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
      ]);
    }
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    if (hours > 0) {
      return '$hours:${twoDigits(minutes)}:${twoDigits(seconds)}';
    }
    return '${twoDigits(minutes)}:${twoDigits(seconds)}';
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Container(
        height: 200,
        decoration: BoxDecoration(
          color: Colors.grey.shade900,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.error_outline,
                color: Colors.red,
                size: 48,
              ),
              const SizedBox(height: 8),
              Text(
                'Unable to play video',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 14,
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (!_isInitialized) {
      return Container(
        height: 200,
        decoration: BoxDecoration(
          color: Colors.grey.shade900,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Center(
          child: CircularProgressIndicator(
            valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
          ),
        ),
      );
    }

    final aspectRatio = _controller.value.aspectRatio > 0 
        ? _controller.value.aspectRatio 
        : 16 / 9;

    if (_isFullScreen) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: GestureDetector(
          onTap: () {
            setState(() {
              _showControls = !_showControls;
            });
          },
          child: Stack(
            children: [
              Center(
                child: AspectRatio(
                  aspectRatio: aspectRatio,
                  child: VideoPlayer(_controller),
                ),
              ),
              
              if (_showControls) ...[
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.black.withOpacity(0.8),
                          Colors.transparent,
                        ],
                      ),
                    ),
                    child: Row(
                      children: [
                        GestureDetector(
                          onTap: _toggleFullScreen,
                          child: const Icon(
                            Icons.fullscreen_exit,
                            color: Colors.white,
                            size: 24,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [
                          Colors.black.withOpacity(0.8),
                          Colors.transparent,
                        ],
                      ),
                    ),
                    child: Row(
                      children: [
                        GestureDetector(
                          onTap: _togglePlay,
                          child: Icon(
                            _isPlaying ? Icons.pause : Icons.play_arrow,
                            color: Colors.white,
                            size: 28,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          _formatDuration(_controller.value.position),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: VideoProgressIndicator(
                            _controller,
                            allowScrubbing: true,
                            colors: const VideoProgressColors(
                              playedColor: Colors.white,
                              bufferedColor: Colors.white30,
                              backgroundColor: Colors.white24,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          _formatDuration(_controller.value.duration),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      );
    }

    return GestureDetector(
      onTap: () {
        setState(() {
          _showControls = !_showControls;
        });
        if (_showControls && _isPlaying) {
          Future.delayed(const Duration(seconds: 3), () {
            if (mounted && _controller.value.isPlaying) {
              setState(() {
                _showControls = false;
              });
            }
          });
        }
      },
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: Colors.black,
        ),
        clipBehavior: Clip.antiAlias,
        child: AspectRatio(
          aspectRatio: aspectRatio,
          child: Stack(
            children: [
              VideoPlayer(_controller),
              
              if (_showControls) ...[
                Center(
                  child: GestureDetector(
                    onTap: _togglePlay,
                    child: AnimatedOpacity(
                      opacity: _isPlaying ? 0.0 : 1.0,
                      duration: const Duration(milliseconds: 200),
                      child: Container(
                        width: 60,
                        height: 60,
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.3),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          _isPlaying ? Icons.pause : Icons.play_arrow,
                          color: Colors.white,
                          size: 35,
                        ),
                      ),
                    ),
                  ),
                ),
                
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [
                          Colors.black.withOpacity(0.8),
                          Colors.transparent,
                        ],
                      ),
                    ),
                    child: Row(
                      children: [
                        GestureDetector(
                          onTap: _togglePlay,
                          child: Icon(
                            _isPlaying ? Icons.pause : Icons.play_arrow,
                            color: Colors.white,
                            size: 20,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _formatDuration(_controller.value.position),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: VideoProgressIndicator(
                            _controller,
                            allowScrubbing: true,
                            colors: const VideoProgressColors(
                              playedColor: Colors.white,
                              bufferedColor: Colors.white30,
                              backgroundColor: Colors.white24,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _formatDuration(_controller.value.duration),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(width: 8),
                        GestureDetector(
                          onTap: _toggleFullScreen,
                          child: const Icon(
                            Icons.fullscreen,
                            color: Colors.white,
                            size: 20,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}