import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/strategy_config_model.dart';
import '../strategies/strategy_registry.dart';
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

/// A dominance candidate captured during the current run. Snapshot lives in
/// the main isolate so the dashboard can rebuild without losing it.
class StrategySessionCandidate {
  final String symbol;
  final double entryPrice;
  final double stopLoss;
  final DateTime time;
  final String status; // 'Watching' | 'Traded'

  const StrategySessionCandidate({
    required this.symbol,
    required this.entryPrice,
    required this.stopLoss,
    required this.time,
    required this.status,
  });

  StrategySessionCandidate copyWith({String? status}) =>
      StrategySessionCandidate(
        symbol: symbol,
        entryPrice: entryPrice,
        stopLoss: stopLoss,
        time: time,
        status: status ?? this.status,
      );
}

/// A trade taken during the current run — built centrally from trade_update
/// events so EVERY strategy (dominance, hammer, ORB…) gets live position
/// cards and a correct Trades count on the dashboard without persisting
/// anything mid-run itself.
class StrategySessionTrade {
  final String symbol;
  final int quantity;
  final double entryPrice;
  final double stopLoss;
  final double exitPrice;
  final double pnl;
  final String status; // 'open' | 'sl_hit' | 'target_hit' | 'eod_exit'
  final DateTime entryTime;
  final DateTime? exitTime;

  const StrategySessionTrade({
    required this.symbol,
    required this.quantity,
    required this.entryPrice,
    required this.stopLoss,
    this.exitPrice = 0,
    this.pnl = 0,
    this.status = 'open',
    required this.entryTime,
    this.exitTime,
  });

  bool get isOpen => status == 'open';

  StrategySessionTrade close(
          {required double exitPrice,
          required double pnl,
          required String status}) =>
      StrategySessionTrade(
        symbol: symbol,
        quantity: quantity,
        entryPrice: entryPrice,
        stopLoss: stopLoss,
        exitPrice: exitPrice,
        pnl: pnl,
        status: status,
        entryTime: entryTime,
        exitTime: DateTime.now(),
      );

  Map<String, dynamic> toJson() => {
        'symbol': symbol,
        'quantity': quantity,
        'entryPrice': entryPrice,
        'stopLoss': stopLoss,
        'exitPrice': exitPrice,
        'pnl': pnl,
        'status': status,
        'entryTime': entryTime.toIso8601String(),
        'exitTime': exitTime?.toIso8601String(),
      };

  factory StrategySessionTrade.fromJson(Map<String, dynamic> m) =>
      StrategySessionTrade(
        symbol: m['symbol'] as String? ?? '',
        quantity: (m['quantity'] as num?)?.toInt() ?? 0,
        entryPrice: (m['entryPrice'] as num?)?.toDouble() ?? 0,
        stopLoss: (m['stopLoss'] as num?)?.toDouble() ?? 0,
        exitPrice: (m['exitPrice'] as num?)?.toDouble() ?? 0,
        pnl: (m['pnl'] as num?)?.toDouble() ?? 0,
        status: m['status'] as String? ?? 'open',
        entryTime: DateTime.tryParse(m['entryTime'] as String? ?? '') ??
            DateTime.now(),
        exitTime: DateTime.tryParse(m['exitTime'] as String? ?? ''),
      );
}

/// Live snapshot of the running strategy's UI-relevant state. The dashboard
/// seeds itself from this on init so widget rebuilds / re-entries don't wipe
/// the phase indicator, status message, progress, candidates, etc.
class StrategySessionState {
  String? configId;
  int currentPhase; // 0=idle, 1=loading, 2=premarket, 3=screening, 4=monitoring, 5=completed
  String statusMessage;
  int progress;
  int candidateCount;
  int activeStocks;
  List<StrategySessionCandidate> candidates;
  List<StrategySessionTrade> trades;

  StrategySessionState({
    this.configId,
    this.currentPhase = 0,
    this.statusMessage = '',
    this.progress = 0,
    this.candidateCount = 0,
    this.activeStocks = 0,
    List<StrategySessionCandidate>? candidates,
    List<StrategySessionTrade>? trades,
  })  : candidates = candidates ?? [],
        trades = trades ?? [];

  StrategySessionState clone() => StrategySessionState(
        configId: configId,
        currentPhase: currentPhase,
        statusMessage: statusMessage,
        progress: progress,
        candidateCount: candidateCount,
        activeStocks: activeStocks,
        candidates: List<StrategySessionCandidate>.from(candidates),
        trades: List<StrategySessionTrade>.from(trades),
      );
}

/// One row in the strategy activity log. Captured centrally so it survives
/// dashboard widget rebuilds and re-entries from the strategy list.
class StrategyActivityRecord {
  final String type; // 'info' | 'signal' | 'trade_entry' | 'trade_sl_hit' | 'trade_target_hit' | 'trade_eod_exit' | 'completed' | 'error'
  final String configId;
  final String message;
  final DateTime time;
  final Map<String, dynamic> data;

  const StrategyActivityRecord({
    required this.type,
    required this.configId,
    required this.message,
    required this.time,
    this.data = const {},
  });
}

/// Manages the Android foreground service for running strategies in background.
class StrategyBackgroundService {
  StrategyBackgroundService._();

  static const _notificationChannelId = 'strategy_service';
  static const _notificationId = 888;
  static const _activityMax = 300;
  static const _kActivityKey = 'strategy_activity_buffer_v1';
  static const _kSessionKey = 'strategy_session_state_v1';

  static final FlutterBackgroundService _service = FlutterBackgroundService();
  static bool _initialized = false;

  // ── Activity buffer + session snapshot (main isolate, survives widget rebuilds) ──
  static final List<StrategyActivityRecord> _activityBuffer = [];
  static String? _activityConfigId;
  static final StreamController<StrategyActivityRecord> _activityCtrl =
      StreamController<StrategyActivityRecord>.broadcast();
  static bool _activityWired = false;
  static final StrategySessionState _session = StrategySessionState();

  /// Past activity entries for the given config. Newest last.
  static List<StrategyActivityRecord> activityFor(String configId) {
    return _activityBuffer
        .where((r) => r.configId == configId)
        .toList(growable: false);
  }

  /// New activity entries as they arrive. Filter by configId on the consumer.
  static Stream<StrategyActivityRecord> get activityStream =>
      _activityCtrl.stream;

  /// Snapshot of the running strategy's UI-relevant state for the given
  /// config. Returns an empty state if the active config doesn't match —
  /// the dashboard is responsible for not seeding from a foreign session.
  static StrategySessionState sessionFor(String configId) {
    if (_session.configId != configId) return StrategySessionState();
    return _session.clone();
  }

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
      await _restoreFromDisk();
      _wireActivityCapture();
      _log('BgService', 'initialize() completed OK');
    } catch (e, stack) {
      _logError('BgService', 'initialize CRASHED: $e\n$stack');
    }
  }

  // ── Disk persistence (survives main-isolate kill) ──
  static Timer? _flushTimer;

  static Future<void> _restoreFromDisk() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      final activityJson = prefs.getString(_kActivityKey);
      if (activityJson != null && activityJson.isNotEmpty) {
        final list = jsonDecode(activityJson) as List;
        _activityBuffer.clear();
        for (final e in list) {
          final m = e as Map<String, dynamic>;
          _activityBuffer.add(StrategyActivityRecord(
            type: m['type'] as String? ?? 'info',
            configId: m['configId'] as String? ?? '',
            message: m['message'] as String? ?? '',
            time: DateTime.tryParse(m['time'] as String? ?? '') ??
                DateTime.now(),
          ));
        }
        if (_activityBuffer.isNotEmpty) {
          _activityConfigId = _activityBuffer.last.configId;
        }
      }

      final sessionJson = prefs.getString(_kSessionKey);
      if (sessionJson != null && sessionJson.isNotEmpty) {
        final m = jsonDecode(sessionJson) as Map<String, dynamic>;
        _session
          ..configId = m['configId'] as String?
          ..currentPhase = (m['currentPhase'] as int?) ?? 0
          ..statusMessage = (m['statusMessage'] as String?) ?? ''
          ..progress = (m['progress'] as int?) ?? 0
          ..candidateCount = (m['candidateCount'] as int?) ?? 0
          ..activeStocks = (m['activeStocks'] as int?) ?? 0
          ..candidates = ((m['candidates'] as List?) ?? [])
              .map((c) {
                final cm = c as Map<String, dynamic>;
                return StrategySessionCandidate(
                  symbol: cm['symbol'] as String? ?? '',
                  entryPrice: (cm['entryPrice'] as num?)?.toDouble() ?? 0,
                  stopLoss: (cm['stopLoss'] as num?)?.toDouble() ?? 0,
                  time: DateTime.tryParse(cm['time'] as String? ?? '') ??
                      DateTime.now(),
                  status: cm['status'] as String? ?? 'Watching',
                );
              })
              .toList()
          ..trades = ((m['trades'] as List?) ?? [])
              .map((t) => StrategySessionTrade.fromJson(
                  Map<String, dynamic>.from(t as Map)))
              .toList();
      }
      _log('BgService',
          'Restored ${_activityBuffer.length} activity rows, ${_session.candidates.length} candidates from disk');
    } catch (e) {
      debugPrint('[BgService] Restore from disk failed: $e');
    }
  }

  /// Debounced flush — coalesces rapid event bursts into one disk write.
  static void _scheduleFlush() {
    _flushTimer?.cancel();
    _flushTimer = Timer(const Duration(milliseconds: 500), _flushToDisk);
  }

  /// Force any pending disk write to complete now. Call from
  /// `AppLifecycleState.paused` so a swipe-away within the debounce window
  /// doesn't lose recent activity.
  static Future<void> flushNow() async {
    _flushTimer?.cancel();
    await _flushToDisk();
  }

  static Future<void> _flushToDisk() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final activityList = _activityBuffer
          .map((r) => {
                'type': r.type,
                'configId': r.configId,
                'message': r.message,
                'time': r.time.toIso8601String(),
              })
          .toList();
      await prefs.setString(_kActivityKey, jsonEncode(activityList));

      final sessionMap = {
        'configId': _session.configId,
        'currentPhase': _session.currentPhase,
        'statusMessage': _session.statusMessage,
        'progress': _session.progress,
        'candidateCount': _session.candidateCount,
        'activeStocks': _session.activeStocks,
        'candidates': _session.candidates
            .map((c) => {
                  'symbol': c.symbol,
                  'entryPrice': c.entryPrice,
                  'stopLoss': c.stopLoss,
                  'time': c.time.toIso8601String(),
                  'status': c.status,
                })
            .toList(),
      };
      sessionMap['trades'] =
          _session.trades.map((t) => t.toJson()).toList();
      await prefs.setString(_kSessionKey, jsonEncode(sessionMap));
    } catch (e) {
      debugPrint('[BgService] Flush to disk failed: $e');
    }
  }

  /// Subscribes once to all service event streams and folds them into a
  /// central buffer. The dashboard reads this buffer on init so the activity
  /// log is preserved across widget rebuilds and re-entries.
  static void _wireActivityCapture() {
    if (_activityWired) return;
    _activityWired = true;

    _service.on('phase').listen((event) {
      if (event == null) return;
      final phase = event['phase'] as String? ?? '';
      final message = event['message'] as String? ?? '';
      switch (phase) {
        case 'loading':
          _session.currentPhase = 1;
        case 'preparing':
        case 'prepared':
          _session.currentPhase = 2;
        case 'screening':
          _session.currentPhase = 3;
      }
      if (message.isNotEmpty) _session.statusMessage = message;
      _scheduleFlush();
    });

    _service.on('update').listen((event) {
      if (event == null) return;
      final status = event['status'] as String?;
      final message = event['message'] as String? ?? '';
      final progress = event['progress'] as int?;
      final candidates = event['candidates'] as int?;
      final activeStocks = event['activeStocks'] as int?;
      final cidRaw = event['configId'] as String?;
      // Transient = status-line refresh (e.g. the ORB heartbeat) — updates
      // the session snapshot but must NOT append an activity row.
      final transient = event['transient'] == true;

      // Every 'running' event marks a fresh run — wipe activity + session so
      // the dashboard starts clean (matches the local clear on Start).
      if (status == 'running' && cidRaw != null && cidRaw.isNotEmpty) {
        _activityBuffer.clear();
        _activityConfigId = cidRaw;
        _session
          ..configId = cidRaw
          ..currentPhase = 1
          ..statusMessage = ''
          ..progress = 0
          ..candidateCount = 0
          ..activeStocks = 0
          ..candidates = []
          ..trades = [];
      }

      if (message.isNotEmpty) _session.statusMessage = message;
      if (progress != null) _session.progress = progress;
      if (candidates != null) _session.candidateCount = candidates;
      if (activeStocks != null) _session.activeStocks = activeStocks;
      final phaseHint = event['phase'] as int?;
      if (phaseHint != null) _session.currentPhase = phaseHint;

      if (message.contains('Fetching') || message.contains('Waiting for')) {
        _session.currentPhase = 3;
      }
      if (message.contains('Monitoring LTP') ||
          message.contains('candidates found')) {
        if (_session.candidateCount > 0) _session.currentPhase = 4;
      }

      if (status == 'stopped' || status == 'completed') {
        _session.progress = 0;
        _session.currentPhase = status == 'completed' ? 5 : 0;
      }

      if (transient) {
        _scheduleFlush();
        return;
      }

      if (message.isNotEmpty) {
        _pushActivity(StrategyActivityRecord(
          type: 'info',
          configId: _activityConfigId ?? cidRaw ?? '',
          message: message,
          time: DateTime.now(),
        ));
      } else {
        // Session changed (progress / counts) without a user-facing message —
        // still need to persist so a cold restart can restore it.
        _scheduleFlush();
      }
    });

    _service.on('signal_found').listen((event) {
      if (event == null) return;
      final symbol = event['symbol'] as String? ?? '';
      final entryNum = (event['entryPrice'] as num?)?.toDouble() ?? 0;
      final slNum = (event['stopLoss'] as num?)?.toDouble() ?? 0;

      _session.candidates.add(StrategySessionCandidate(
        symbol: symbol,
        entryPrice: entryNum,
        stopLoss: slNum,
        time: DateTime.now(),
        status: 'Watching',
      ));
      _session.candidateCount = _session.candidates.length;
      _session.currentPhase = 4;

      _pushActivity(StrategyActivityRecord(
        type: 'signal',
        configId: _activityConfigId ?? '',
        message:
            'DOMINANCE: $symbol Entry=${entryNum.toStringAsFixed(1)} SL=${slNum.toStringAsFixed(1)}',
        time: DateTime.now(),
        data: Map<String, dynamic>.from(event),
      ));
    });

    _service.on('trade_update').listen((event) {
      if (event == null) return;
      final type = event['type'] as String? ?? '';
      final symbol = event['symbol'] as String? ?? '';
      final isPaper = event['isPaper'] as bool? ?? true;

      // Maintain the session trades list — the dashboard's position cards
      // and Trades count come from here, for every strategy shape.
      if (type == 'entry') {
        _session.trades.add(StrategySessionTrade(
          symbol: symbol,
          quantity: (event['quantity'] as num?)?.toInt() ?? 0,
          entryPrice: (event['entryPrice'] as num?)?.toDouble() ?? 0,
          stopLoss: (event['stopLoss'] as num?)?.toDouble() ?? 0,
          entryTime: DateTime.now(),
        ));
      } else if (type == 'sl_hit' ||
          type == 'target_hit' ||
          type == 'eod_exit') {
        for (int i = _session.trades.length - 1; i >= 0; i--) {
          final t = _session.trades[i];
          if (t.symbol == symbol && t.isOpen) {
            _session.trades[i] = t.close(
              exitPrice: (event['exitPrice'] as num?)?.toDouble() ?? 0,
              pnl: (event['pnl'] as num?)?.toDouble() ?? 0,
              status: type,
            );
            break;
          }
        }
      }

      // Mark the matching candidate as 'Traded' on entry.
      if (type == 'entry') {
        for (int i = 0; i < _session.candidates.length; i++) {
          final c = _session.candidates[i];
          if (c.symbol == symbol && c.status == 'Watching') {
            _session.candidates[i] = c.copyWith(status: 'Traded');
            break;
          }
        }
      }

      String message;
      if (type == 'entry') {
        final qty = event['quantity'];
        final entry = event['entryPrice'];
        message = '${isPaper ? "[PAPER]" : "[LIVE]"} BUY $symbol Qty=$qty @ $entry';
      } else if (type == 'sl_hit') {
        final pnl = (event['pnl'] as num?)?.toStringAsFixed(0) ?? '0';
        message = 'SL HIT: $symbol P&L=Rs $pnl';
      } else if (type == 'target_hit') {
        final pnl = (event['pnl'] as num?)?.toStringAsFixed(0) ?? '0';
        message = 'TARGET: $symbol P&L=Rs $pnl';
      } else if (type == 'eod_exit') {
        message = 'EOD EXIT: $symbol';
      } else {
        message = '$type: $symbol';
      }
      _pushActivity(StrategyActivityRecord(
        type: 'trade_$type',
        configId: _activityConfigId ?? '',
        message: message,
        time: DateTime.now(),
        data: Map<String, dynamic>.from(event),
      ));
    });

    _service.on('completed').listen((event) {
      if (event == null) return;
      _session.currentPhase = 5;
      _session.progress = 0;
      _pushActivity(StrategyActivityRecord(
        type: 'completed',
        configId: _activityConfigId ?? '',
        message: event['message'] as String? ?? 'Strategy completed',
        time: DateTime.now(),
      ));
    });

    _service.on('error').listen((event) {
      if (event == null) return;
      _pushActivity(StrategyActivityRecord(
        type: 'error',
        configId: _activityConfigId ?? '',
        message: event['message'] as String? ?? 'Error occurred',
        time: DateTime.now(),
      ));
    });
  }

  static void _pushActivity(StrategyActivityRecord r) {
    _activityBuffer.add(r);
    if (_activityBuffer.length > _activityMax) {
      _activityBuffer.removeAt(0);
    }
    if (!_activityCtrl.isClosed) {
      _activityCtrl.add(r);
    }
    _scheduleFlush();
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

  // The background isolate has its OWN memory — the StrategyRegistry populated
  // by main() is NOT shared here. Without this, StrategyRegistry.create() for a
  // self-contained strategy (e.g. hammer_dominance_s1) returns null and the
  // engine silently falls back to the hardcoded Dominance inline path — i.e. a
  // Hammer config would run Dominance live. Re-init the registry per isolate
  // (idempotent), exactly like AppLogger.init() must run in each isolate.
  StrategyRegistry.init();
  debugPrint('[BgIsolate] StrategyRegistry initialized');

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

  // ── Idle watchdog ──
  // The plugin's native watchdog revives a service that died WITHOUT an
  // explicit stopSelf() (system kill, force-stop). The revived isolate has no
  // engine — nobody sent start_strategy — and previously sat forever showing
  // "Initializing...". A real Run sends start_strategy within ~1s of service
  // start, so if nothing arrives inside the grace window, shut down cleanly
  // (stopSelf also clears the plugin's respawn state). A dead strategy can't
  // be resumed by a revived isolate anyway, so nothing is lost.
  Timer? idleWatchdog;
  idleWatchdog = Timer(const Duration(seconds: 25), () async {
    if (engine != null) return;
    debugPrint(
        '[BgIsolate] Idle watchdog: no strategy started within 25s — stopping service');
    try {
      await FlutterLocalNotificationsPlugin().cancel(888);
    } catch (_) {}
    service.stopSelf();
  });

  service.on('start_strategy').listen((event) async {
    idleWatchdog?.cancel();
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
    idleWatchdog?.cancel();
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
