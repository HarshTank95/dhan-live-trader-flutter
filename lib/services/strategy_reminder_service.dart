import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import '../models/strategy_config_model.dart';
import '../screens/strategy_dashboard_screen.dart';
import '../screens/token_entry_screen.dart';
import 'app_logger.dart';
import 'storage_service.dart';
import 'strategy_background_service.dart';

/// Per-strategy pre-market reminder notifications.
///
/// Each enabled strategy gets 5 weekly notifications (Mon–Fri) at
/// `9:15 - reminderMinutesBefore` IST. Notifications use the device's
/// inexact alarm scheduler so no SCHEDULE_EXACT_ALARM permission is needed.
/// Tapping the notification opens that strategy's dashboard directly.
class StrategyReminderService {
  StrategyReminderService._();

  static const _channelId = 'strategy_reminder';
  static const _channelName = 'Strategy Reminders';
  static const _channelDesc =
      'Pre-market reminders to start your trading strategies';

  /// Action ID for the "Start Now" button on the reminder notification.
  /// When the user taps it, the tap handler starts the strategy in addition
  /// to opening the dashboard.
  static const _actionStartNow = 'start_now';

  /// Market open is 9:15 AM IST — the same hardcoded constant used elsewhere
  /// in the codebase. Reminder fires at `_marketOpenMinutes - leadMinutes`.
  static const int _marketOpenMinutes = 9 * 60 + 15;

  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  static GlobalKey<NavigatorState>? _navKey;
  static bool _initialized = false;

  /// Initialize timezone DB, plugin tap handler, and the reminder channel.
  /// Call after `StrategyBackgroundService.initialize()` from `main.dart`.
  static Future<void> initialize(GlobalKey<NavigatorState> navKey) async {
    if (_initialized) return;
    _navKey = navKey;

    try {
      tz_data.initializeTimeZones();
      tz.setLocalLocation(tz.getLocation('Asia/Kolkata'));

      const initSettings = InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      );
      await _plugin.initialize(
        initSettings,
        onDidReceiveNotificationResponse: _onNotificationTap,
      );

      const channel = AndroidNotificationChannel(
        _channelId,
        _channelName,
        description: _channelDesc,
        importance: Importance.high,
        enableVibration: true,
        playSound: true,
      );
      await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(channel);

      _initialized = true;
      AppLogger.info(
        'Reminder',
        'StrategyReminderService initialized | tz=${tz.local.name} now=${_fmtTs(tz.TZDateTime.now(tz.local))}',
      );
    } catch (e, s) {
      debugPrint('[Reminder] initialize failed: $e\n$s');
    }
  }

  /// Schedule (or re-schedule) a reminder for a single strategy.
  /// Cancels any previous schedule for this configId first.
  static Future<void> scheduleReminder(StrategyConfigModel config) async {
    if (!_initialized) return;

    await cancelReminder(config.id);

    if (!config.reminderEnabled || config.reminderMinutesBefore <= 0) return;

    final reminderMinuteOfDay =
        _marketOpenMinutes - config.reminderMinutesBefore;
    final hour = reminderMinuteOfDay ~/ 60;
    final minute = reminderMinuteOfDay % 60;
    final mode = config.paperTrading ? 'Paper' : 'Live';
    final body =
        'Starts in ${config.reminderMinutesBefore} min ($mode) — tap to open';
    final payload = jsonEncode({
      'type': 'reminder',
      'configId': config.id,
    });
    final base = _baseId(config.id);

    AppLogger.info(
      'Reminder',
      'Scheduling "${config.name}" (cfg=${config.id}) baseId=$base '
      'fire=${_fmtClock(reminderMinuteOfDay)} IST lead=${config.reminderMinutesBefore}m mode=$mode',
    );

    // Schedule one notification per weekday (Mon..Fri = DateTime.monday..friday).
    for (int weekday = DateTime.monday; weekday <= DateTime.friday; weekday++) {
      final next = _nextOccurrence(weekday, hour, minute);
      final dayOffset = weekday - DateTime.monday;
      final notifId = base + dayOffset;

      try {
        await _plugin.zonedSchedule(
          notifId,
          'Pre-market reminder: ${config.name}',
          body,
          next,
          NotificationDetails(
            android: AndroidNotificationDetails(
              _channelId,
              _channelName,
              channelDescription: _channelDesc,
              importance: Importance.high,
              priority: Priority.high,
              category: AndroidNotificationCategory.reminder,
              actions: const [
                AndroidNotificationAction(
                  _actionStartNow,
                  'Start Now',
                  showsUserInterface: true,
                  cancelNotification: true,
                ),
              ],
            ),
          ),
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          uiLocalNotificationDateInterpretation:
              UILocalNotificationDateInterpretation.absoluteTime,
          matchDateTimeComponents: DateTimeComponents.dayOfWeekAndTime,
          payload: payload,
        );
        AppLogger.info(
          'Reminder',
          '  slot ${_weekdayName(weekday)} id=$notifId → next fire ${_fmtTs(next)} ${next.timeZoneName}',
        );
      } catch (e, s) {
        AppLogger.error(
          'Reminder',
          'zonedSchedule FAILED "${config.name}" ${_weekdayName(weekday)} id=$notifId: $e\n$s',
        );
      }
    }

    AppLogger.info(
      'Reminder',
      'Scheduled ${config.name} at ${_fmtClock(reminderMinuteOfDay)} IST (Mon–Fri, ${config.reminderMinutesBefore} min before market open)',
    );
    await logPendingReminders('after-schedule:${config.name}');
  }

  /// Cancel all 5 weekday slots for a given strategy.
  static Future<void> cancelReminder(String configId) async {
    if (!_initialized) return;
    final base = _baseId(configId);
    for (int dayOffset = 0; dayOffset < 5; dayOffset++) {
      try {
        await _plugin.cancel(base + dayOffset);
      } catch (_) {}
    }
  }

  /// Request POST_NOTIFICATIONS at runtime (Android 13+). Required before any
  /// scheduled notification will actually appear — declaring it in the
  /// manifest is not enough. Returns true if granted (or N/A on this OS).
  static Future<bool> requestPermission() async {
    if (!_initialized) return false;
    try {
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      if (android == null) return true;
      final granted = await android.requestNotificationsPermission();
      AppLogger.info('Reminder', 'Notification permission: ${granted ?? false}');
      return granted ?? false;
    } catch (e) {
      debugPrint('[Reminder] requestPermission failed: $e');
      return false;
    }
  }

  /// Fire a one-shot notification immediately so the user can verify the
  /// reminder pipeline end-to-end without waiting until tomorrow morning.
  /// Uses the same channel as scheduled reminders so per-channel mute state
  /// is exercised too.
  static Future<void> sendTestNotification(StrategyConfigModel config) async {
    if (!_initialized) return;
    try {
      final mode = config.paperTrading ? 'Paper' : 'Live';
      await _plugin.show(
        _baseId(config.id) + 5, // +5 keeps it clear of the 5 weekday slots
        'Test reminder: ${config.name}',
        'Reminder pipeline is working ($mode) — tap to open or Start Now',
        NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            _channelName,
            channelDescription: _channelDesc,
            importance: Importance.high,
            priority: Priority.high,
            category: AndroidNotificationCategory.reminder,
            actions: const [
              AndroidNotificationAction(
                _actionStartNow,
                'Start Now',
                showsUserInterface: true,
                cancelNotification: true,
              ),
            ],
          ),
        ),
        payload: jsonEncode({'type': 'reminder', 'configId': config.id}),
      );
      AppLogger.info('Reminder', 'Test notification fired for ${config.name}');
    } catch (e) {
      debugPrint('[Reminder] sendTestNotification failed: $e');
    }
  }

  /// Cancel everything and re-schedule reminders for every enabled config.
  /// Idempotent. Call on app startup so reminders survive cold starts and
  /// reboots without piling up duplicates.
  static Future<void> syncAllReminders(
      List<StrategyConfigModel> configs) async {
    if (!_initialized) return;
    try {
      AppLogger.info(
        'Reminder',
        'syncAllReminders: ${configs.length} config(s) — '
        '${configs.map((c) => "${c.name}[rem=${c.reminderEnabled},lead=${c.reminderMinutesBefore}m,enabled=${c.enabled}]").join(" | ")}',
      );
      // Cancel only this app's reminder IDs (don't nuke the foreground service).
      for (final c in configs) {
        await cancelReminder(c.id);
      }
      for (final c in configs) {
        if (c.reminderEnabled) {
          await scheduleReminder(c);
        }
      }
      AppLogger.info('Reminder',
          'Synced ${configs.where((c) => c.reminderEnabled).length} active reminder(s)');
      await logPendingReminders('after-sync');
      await logActiveReminders('startup');
    } catch (e) {
      debugPrint('[Reminder] syncAllReminders failed: $e');
    }
  }

  // ── Internals ──────────────────────────────────────────────────────────

  /// Deterministic base ID per config. The 0xFFFF mask gives a 16-bit slot
  /// per config, offset by 100000 so it never collides with the foreground
  /// service notification (id 888).
  static int _baseId(String configId) =>
      100000 + (configId.hashCode & 0xFFFF);

  /// Next IST occurrence of the given weekday at HH:MM. If today is that
  /// weekday and the time is still in the future, returns today; otherwise
  /// returns the upcoming match (1–7 days ahead).
  static tz.TZDateTime _nextOccurrence(int weekday, int hour, int minute) {
    final now = tz.TZDateTime.now(tz.local);
    var candidate = tz.TZDateTime(
      tz.local,
      now.year,
      now.month,
      now.day,
      hour,
      minute,
    );
    // Walk forward until we hit the right weekday at a future timestamp.
    while (candidate.weekday != weekday || !candidate.isAfter(now)) {
      candidate = candidate.add(const Duration(days: 1));
    }
    return candidate;
  }

  static String _fmtClock(int minuteOfDay) {
    final h24 = minuteOfDay ~/ 60;
    final m = minuteOfDay % 60;
    final period = h24 >= 12 ? 'PM' : 'AM';
    final h12 = h24 == 0 ? 12 : (h24 > 12 ? h24 - 12 : h24);
    return '$h12:${m.toString().padLeft(2, '0')} $period';
  }

  static String _weekdayName(int weekday) {
    const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return names[(weekday - 1).clamp(0, 6)];
  }

  static String _fmtTs(tz.TZDateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  /// Dump the plugin's view of scheduled reminders to the app log. The single
  /// most useful "did it actually register?" check — compare against
  /// `adb shell dumpsys alarm`. Reminder slot IDs are >= 100000 (see _baseId).
  static Future<void> logPendingReminders(String context) async {
    if (!_initialized) return;
    try {
      final pending = await _plugin.pendingNotificationRequests();
      final mine = pending.where((p) => p.id >= 100000).toList();
      AppLogger.info(
        'Reminder',
        'PENDING[$context]: ${pending.length} total / ${mine.length} reminder slot(s) '
        '| now=${_fmtTs(tz.TZDateTime.now(tz.local))}',
      );
      for (final p in mine) {
        AppLogger.info(
            'Reminder', '  pending id=${p.id} "${p.title}" — ${p.body}');
      }
    } catch (e) {
      AppLogger.error('Reminder', 'logPendingReminders[$context] failed: $e');
    }
  }

  /// Log notifications currently showing in the system tray (Android). On app
  /// start this reveals whether a fired reminder is still sitting undismissed —
  /// concrete proof of overnight delivery when "did it fire?" is the question.
  static Future<void> logActiveReminders(String context) async {
    if (!_initialized) return;
    try {
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      if (android == null) return;
      final active = await android.getActiveNotifications();
      final mine = active.where((a) => (a.id ?? 0) >= 100000).toList();
      AppLogger.info(
        'Reminder',
        'ACTIVE[$context]: ${active.length} in tray / ${mine.length} reminder(s) showing',
      );
      for (final a in mine) {
        AppLogger.info('Reminder', '  active id=${a.id} "${a.title}"');
      }
    } catch (e) {
      AppLogger.error('Reminder', 'logActiveReminders[$context] failed: $e');
    }
  }

  /// Notification tap handler — runs on the main isolate. Decodes the
  /// payload and pushes the strategy dashboard, or routes to the token
  /// entry screen if credentials aren't saved yet. If the user tapped the
  /// "Start Now" action, also kicks off the foreground service before
  /// navigating so the strategy is already running by the time the
  /// dashboard appears.
  static Future<void> _onNotificationTap(NotificationResponse response) async {
    AppLogger.info(
      'Reminder',
      'TAP received: actionId=${response.actionId ?? "(body)"} payload=${response.payload}',
    );
    final payload = response.payload;
    if (payload == null || payload.isEmpty) return;

    String? configId;
    try {
      final data = jsonDecode(payload) as Map<String, dynamic>;
      if (data['type'] != 'reminder') return;
      configId = data['configId'] as String?;
    } catch (_) {
      return;
    }
    if (configId == null) return;

    final navState = _navKey?.currentState;
    if (navState == null) return;

    // Find the config — bail quietly if it was deleted.
    final configs = await StorageService.loadStrategyConfigs();
    final config = configs.where((c) => c.id == configId).firstOrNull;
    if (config == null) return;

    final creds = await StorageService.loadCredentials();
    if (creds == null) {
      // Logged out — just bring them to the login screen.
      navState.push(MaterialPageRoute(
        builder: (_) => const TokenEntryScreen(),
      ));
      return;
    }

    // If the user tapped "Start Now", launch the strategy before navigating.
    // We don't block navigation on the result — the dashboard subscribes to
    // the activity stream and will reflect the running state once it's up.
    if (response.actionId == _actionStartNow) {
      if (!config.enabled) {
        AppLogger.info('Reminder',
            'Start Now ignored — ${config.name} is paused (enabled=false)');
      } else {
        unawaited(_startStrategyFromReminder(config, creds));
      }
    }

    navState.push(MaterialPageRoute(
      builder: (_) => StrategyDashboardScreen(
        config: config,
        clientId: creds.clientId,
        accessToken: creds.accessToken,
      ),
    ));
  }

  static Future<void> _startStrategyFromReminder(
    StrategyConfigModel config,
    ({String clientId, String accessToken}) creds,
  ) async {
    try {
      final started = await StrategyBackgroundService.startService(
        configId: config.id,
        strategyType: config.strategyType,
        configName: config.name,
        isPaper: config.paperTrading,
        clientId: creds.clientId,
        accessToken: creds.accessToken,
        configJson: config.toJson(),
      );
      AppLogger.info(
          'Reminder', 'Start Now → service started=$started for ${config.name}');
    } catch (e) {
      AppLogger.error('Reminder', 'Start Now failed: $e');
    }
  }
}
