import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'screens/token_entry_screen.dart';
import 'screens/ltp_screen.dart';
import 'services/app_logger.dart';
import 'services/storage_service.dart';
import 'services/strategy_background_service.dart';
import 'strategies/strategy_registry.dart';

void main() async {
  // Wrap entire app in error zone to catch ALL async errors
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();

    // Catch all uncaught Flutter framework errors
    FlutterError.onError = (details) {
      debugPrint('[FlutterError] ${details.exceptionAsString()}');
      AppLogger.error('Flutter', details.exceptionAsString());
      if (details.stack != null) {
        AppLogger.error('Flutter', details.stack.toString());
      }
    };

    // Catch errors during rendering
    PlatformDispatcher.instance.onError = (error, stack) {
      debugPrint('[PlatformError] $error');
      AppLogger.error('Platform', '$error\n$stack');
      return true;
    };

    await AppLogger.init();
    AppLogger.info('App', 'App starting... (${DateTime.now()})');

    StrategyRegistry.init();
    AppLogger.info('App', 'StrategyRegistry initialized');

    await StrategyBackgroundService.initialize();
    AppLogger.info('App', 'BackgroundService initialized');

    final saved = await StorageService.loadCredentials();
    final isDark = await StorageService.loadTheme();

    AppLogger.info('App', 'App initialized, launching UI');
    runApp(MyApp(savedCredentials: saved, isDark: isDark));
  }, (error, stack) {
    // This catches ANY uncaught async error in the entire app
    debugPrint('[ZoneError] $error');
    debugPrint('[ZoneError] $stack');
    try {
      AppLogger.error('Zone', '$error\n$stack');
    } catch (_) {}
  });
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
