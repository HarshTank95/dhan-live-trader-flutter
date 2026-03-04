import 'package:flutter/material.dart';
import 'screens/token_entry_screen.dart';
import 'screens/ltp_screen.dart';
import 'services/storage_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final saved = await StorageService.loadCredentials();
  final isDark = await StorageService.loadTheme();
  runApp(MyApp(savedCredentials: saved, isDark: isDark));
}

class MyApp extends StatefulWidget {
  final ({String clientId, String accessToken})? savedCredentials;
  final bool isDark;

  const MyApp({super.key, this.savedCredentials, required this.isDark});

  static _MyAppState of(BuildContext context) =>
      context.findAncestorStateOfType<_MyAppState>()!;

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  late bool _isDark;

  bool get isDark => _isDark;

  @override
  void initState() {
    super.initState();
    _isDark = widget.isDark;
  }

  void toggleTheme() async {
    setState(() => _isDark = !_isDark);
    await StorageService.saveTheme(_isDark);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Dhan LTP Viewer',
      debugShowCheckedModeBanner: false,
      themeMode: _isDark ? ThemeMode.dark : ThemeMode.light,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: widget.savedCredentials != null
          ? LtpScreen(
              clientId: widget.savedCredentials!.clientId,
              accessToken: widget.savedCredentials!.accessToken,
            )
          : const TokenEntryScreen(),
    );
  }
}
