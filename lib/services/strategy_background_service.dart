import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../models/strategy_config_model.dart';
import 'app_logger.dart';
import 'strategy_engine.dart';

/// Log helper that writes to both AppLogger (file) AND debugPrint (logcat).
/// Ensures we capture logs even if one system fails.
void _log(String tag, String msg) {
  final line = '[$tag] $msg';
  debugPrint(line);
  try {
    AppLogger.info(tag, msg);
  } catch (_) {}
}

void _logError(String tag, String msg) {
  final line = '[$tag] ERROR: $msg';
  debugPrint(line);
  try {
    AppLogger.error(tag, msg);
  } catch (_) {}
}

/// Manages the Android foreground service for running strategies in background.
class StrategyBackgroundService {
  StrategyBackgroundService._();

  static const _notificationChannelId = 'strategy_service';
  static const _notificationId = 888;

  static final FlutterBackgroundService _service = FlutterBackgroundService();
  static bool _initialized = false;

  /// Initialize the background service. Call once at app startup.
  static Future<void> initialize() async {
    if (_initialized) return;

    try {
      _log('BgService', 'initialize() starting...');

      // Create notification channel for Android
      final flutterLocalNotificationsPlugin =
          FlutterLocalNotificationsPlugin();

      const androidChannel = AndroidNotificationChannel(
        _notificationChannelId,
        'Strategy Service',
        description: 'Keeps the trading strategy running in background',
        importance: Importance.low,
      );

      _log('BgService', 'Creating notification channel...');
      await flutterLocalNotificationsPlugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(androidChannel);
      _log('BgService', 'Notification channel created');

      _log('BgService', 'Configuring service...');
      await _service.configure(
        androidConfiguration: AndroidConfiguration(
          onStart: onStart,
          autoStart: false,
          isForegroundMode: true,
          foregroundServiceTypes: [AndroidForegroundType.dataSync],
          notificationChannelId: _notificationChannelId,
          initialNotificationTitle: 'Dhan Strategy',
          initialNotificationContent: 'Initializing...',
          foregroundServiceNotificationId: _notificationId,
        ),
        iosConfiguration: IosConfiguration(
          autoStart: false,
          onForeground: onStart,
        ),
      );

      _initialized = true;
      _log('BgService', 'initialize() completed OK');
    } catch (e, stack) {
      _logError('BgService', 'initialize CRASHED: $e\n$stack');
    }
  }

  /// Request notification permission (required on Android 13+).
  static Future<bool> requestPermission() async {
    try {
      _log('BgService', 'Requesting notification permission...');
      final plugin = FlutterLocalNotificationsPlugin();
      final android = plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      if (android == null) {
        _log('BgService', 'Not Android platform, skipping permission');
        return true;
      }

      final granted = await android.requestNotificationsPermission();
      _log('BgService', 'Notification permission result: ${granted ?? false}');
      return granted ?? false;
    } catch (e, stack) {
      _logError('BgService', 'requestPermission CRASHED: $e\n$stack');
      return false;
    }
  }

  /// Start the foreground service and begin strategy execution.
  static Future<bool> startService({
    required String configId,
    required String strategyType,
    required String configName,
    required bool isPaper,
    required String clientId,
    required String accessToken,
    required Map<String, dynamic> configJson,
  }) async {
    try {
      _log('BgService', '── startService BEGIN ──');
      _log('BgService', 'Config: $configName ($strategyType) paper=$isPaper id=$configId');
      _log('BgService', 'Service initialized: $_initialized');

      if (!_initialized) {
        _logError('BgService', 'Service NOT initialized! Calling initialize()...');
        await initialize();
      }

      // Request notification permission first (Android 13+)
      final hasPermission = await requestPermission();
      if (!hasPermission) {
        _logError('BgService', 'Notification permission DENIED — cannot start');
        return false;
      }

      _log('BgService', 'Checking if service already running...');
      final isRunning = await _service.isRunning();
      _log('BgService', 'Service already running: $isRunning');

      if (!isRunning) {
        _log('BgService', '>>> Calling _service.startService() NOW <<<');
        await _service.startService();
        _log('BgService', '>>> _service.startService() returned OK <<<');
      }

      // Give service a moment to start, then send config
      _log('BgService', 'Waiting 500ms for service to start...');
      await Future.delayed(const Duration(milliseconds: 500));

      _log('BgService', 'Checking service running after delay...');
      final runningAfterStart = await _service.isRunning();
      _log('BgService', 'Service running after start: $runningAfterStart');

      _log('BgService', 'Sending start_strategy event...');
      _service.invoke('start_strategy', {
        'configId': configId,
        'strategyType': strategyType,
        'configName': configName,
        'isPaper': isPaper,
        'clientId': clientId,
        'accessToken': accessToken,
        'configJson': configJson,
      });

      _log('BgService', '── startService END (success) ──');
      return true;
    } catch (e, stack) {
      _logError('BgService', 'startService CRASHED: $e\n$stack');
      return false;
    }
  }

  /// Stop the foreground service.
  static Future<void> stopService() async {
    try {
      _log('BgService', 'stopService called');
      _service.invoke('stop');
      _log('BgService', 'stop event sent');
    } catch (e, stack) {
      _logError('BgService', 'stopService CRASHED: $e\n$stack');
    }
  }

  /// Check if the service is currently running.
  static Future<bool> isRunning() async {
    try {
      return await _service.isRunning();
    } catch (_) {
      return false;
    }
  }

  /// Listen for updates from the background service.
  static Stream<Map<String, dynamic>?> get onUpdate => _service.on('update');
  static Stream<Map<String, dynamic>?> get onPhase => _service.on('phase');
  static Stream<Map<String, dynamic>?> get onSignal =>
      _service.on('signal_found');
  static Stream<Map<String, dynamic>?> get onTrade =>
      _service.on('trade_update');
  static Stream<Map<String, dynamic>?> get onCompleted =>
      _service.on('completed');
  static Stream<Map<String, dynamic>?> get onError => _service.on('error');
}

/// Updates the ongoing (non-dismissable) foreground notification.
/// Fire-and-forget — safe to call from non-async callbacks.
void _updateOngoingNotification(String title, String content) {
  final notifPlugin = FlutterLocalNotificationsPlugin();
  notifPlugin.show(
    888, // same ID as foreground service notification
    title,
    content,
    const NotificationDetails(
      android: AndroidNotificationDetails(
        'strategy_service',
        'Strategy Service',
        importance: Importance.low,
        priority: Priority.low,
        ongoing: true,
        autoCancel: false,
        playSound: false,
        enableVibration: false,
      ),
    ),
  );
}

// ─── Background isolate entry point ─────────────────────────────────────
// MUST be a top-level NON-PRIVATE function for the isolate to find it.
// NOTE: This runs in a SEPARATE isolate — no access to AppLogger file.
//       Use debugPrint (logcat) + service.invoke to send logs to UI.

@pragma('vm:entry-point')
Future<void> onStart(ServiceInstance service) async {
  // ── STEP 1: Plugin registration ──
  debugPrint('[BgIsolate] onStart() ENTERED');
  try {
    DartPluginRegistrant.ensureInitialized();
    debugPrint('[BgIsolate] DartPluginRegistrant OK');
  } catch (e) {
    debugPrint('[BgIsolate] DartPluginRegistrant FAILED: $e');
  }

  // ── STEP 2: Android foreground/background listeners ──
  debugPrint('[BgIsolate] Service type: ${service.runtimeType}');
  if (service is AndroidServiceInstance) {
    debugPrint('[BgIsolate] Setting up Android service listeners...');
    service.on('setAsForeground').listen((_) {
      debugPrint('[BgIsolate] setAsForeground received');
      service.setAsForegroundService();
    });
    service.on('setAsBackground').listen((_) {
      debugPrint('[BgIsolate] setAsBackground received');
      service.setAsBackgroundService();
    });
    debugPrint('[BgIsolate] Android listeners ready');
  }

  // ── STEP 2.5: Make notification non-dismissable (ongoing) ──
  // Foreground service notifications can be swiped away by default,
  // which kills the service. We replace it with an ongoing notification.
  try {
    final notifPlugin = FlutterLocalNotificationsPlugin();
    await notifPlugin.show(
      888, // same ID as foreground service notification
      'Dhan Strategy',
      'Initializing...',
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'strategy_service', // same channel ID
          'Strategy Service',
          importance: Importance.low,
          priority: Priority.low,
          ongoing: true, // NON-DISMISSABLE — cannot be swiped away
          autoCancel: false,
          playSound: false,
          enableVibration: false,
        ),
      ),
    );
    debugPrint('[BgIsolate] Ongoing notification set');
  } catch (e) {
    debugPrint('[BgIsolate] Failed to set ongoing notification: $e');
  }

  // Send alive signal to UI immediately
  service.invoke('update', {
    'status': 'isolate_started',
    'message': 'Background isolate is alive',
  });
  debugPrint('[BgIsolate] Sent isolate_started event to UI');

  // ── STEP 3: Handle START command from UI ──
  StrategyEngine? engine;

  service.on('start_strategy').listen((event) async {
    debugPrint('[BgIsolate] start_strategy event received: $event');
    if (event == null) {
      debugPrint('[BgIsolate] start_strategy event is NULL, ignoring');
      return;
    }

    final configId = event['configId'] as String? ?? '';
    final configName = event['configName'] as String? ?? 'Strategy';
    final strategyType = event['strategyType'] as String? ?? '';
    final isPaper = event['isPaper'] as bool? ?? true;
    final clientId = event['clientId'] as String? ?? '';
    final accessToken = event['accessToken'] as String? ?? '';
    final configJson = event['configJson'] as Map<String, dynamic>?;
    final mode = isPaper ? 'Paper' : 'LIVE';

    debugPrint('[BgIsolate] Strategy: $configName ($strategyType) mode=$mode id=$configId');
    debugPrint('[BgIsolate] ClientId: ${clientId.isNotEmpty ? "present" : "MISSING"}');
    debugPrint('[BgIsolate] AccessToken: ${accessToken.isNotEmpty ? "present" : "MISSING"}');

    if (clientId.isEmpty || accessToken.isEmpty) {
      debugPrint('[BgIsolate] ERROR: Missing clientId or accessToken!');
      service.invoke('error', {
        'message': 'Cannot start — missing API credentials',
      });
      return;
    }

    // Build StrategyConfigModel from JSON or defaults
    StrategyConfigModel config;
    if (configJson != null) {
      try {
        config = StrategyConfigModel.fromJson(configJson);
      } catch (e) {
        debugPrint('[BgIsolate] Config parse error: $e — using defaults');
        config = StrategyConfigModel(
          id: configId,
          strategyType: strategyType,
          name: configName,
          paperTrading: isPaper,
          params: {},
        );
      }
    } else {
      config = StrategyConfigModel(
        id: configId,
        strategyType: strategyType,
        name: configName,
        paperTrading: isPaper,
        params: {},
      );
    }

    // Update notification
    if (service is AndroidServiceInstance) {
      service.setForegroundNotificationInfo(
        title: '$configName ($mode)',
        content: 'Loading instruments...',
      );
    }

    // Send initial status to UI
    service.invoke('update', {
      'status': 'running',
      'configId': configId,
      'message': 'Strategy $configName started in $mode mode',
    });

    // Create and run the Strategy Engine
    debugPrint('[BgIsolate] Creating Strategy Engine...');
    engine = StrategyEngine(
      clientId: clientId,
      accessToken: accessToken,
      config: config,
      onUpdate: (String eventName, Map<String, dynamic> data) {
        debugPrint('[BgIsolate] Engine event: $eventName → $data');

        // Forward engine events to UI
        service.invoke(eventName, data);

        // Update ongoing notification with latest status
        final msg = data['message'] as String? ?? '';
        if (msg.isNotEmpty) {
          _updateOngoingNotification('$configName ($mode)', msg);
        }
      },
    );

    debugPrint('[BgIsolate] Running Strategy Engine...');
    try {
      await engine!.run();
      debugPrint('[BgIsolate] Strategy Engine completed');
    } catch (e, stack) {
      debugPrint('[BgIsolate] Strategy Engine CRASHED: $e\n$stack');
      service.invoke('error', {'message': 'Engine crashed: $e'});
    }

    // Engine completed — update notification and stop
    if (service is AndroidServiceInstance) {
      service.setForegroundNotificationInfo(
        title: '$configName ($mode)',
        content: 'Completed',
      );
    }
    service.invoke('completed', {
      'message': 'Strategy completed for today',
    });

    // Auto-stop after 5 seconds
    await Future.delayed(const Duration(seconds: 5));
    service.stopSelf();
  });

  // ── STEP 4: Handle STOP command from UI ──
  service.on('stop').listen((_) async {
    debugPrint('[BgIsolate] STOP command received');

    // Stop the strategy engine if running
    if (engine != null && engine!.isRunning) {
      debugPrint('[BgIsolate] Stopping Strategy Engine...');
      engine!.stop();
    }

    service.invoke('update', {
      'status': 'stopped',
      'message': 'Strategy stopped by user',
    });

    // Cancel the ongoing notification
    try {
      final notifPlugin = FlutterLocalNotificationsPlugin();
      await notifPlugin.cancel(888);
      debugPrint('[BgIsolate] Notification cancelled');
    } catch (e) {
      debugPrint('[BgIsolate] Failed to cancel notification: $e');
    }

    if (service is AndroidServiceInstance) {
      service.setForegroundNotificationInfo(
        title: 'Dhan Strategy',
        content: 'Stopped',
      );
    }

    debugPrint('[BgIsolate] Stopping self in 300ms...');
    await Future.delayed(const Duration(milliseconds: 300));
    debugPrint('[BgIsolate] Calling stopSelf()');
    service.stopSelf();
  });

  debugPrint('[BgIsolate] onStart() setup COMPLETE — all listeners registered');
}
