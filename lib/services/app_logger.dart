import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Simple file-based logger. Writes to app_log.txt on device storage.
/// Access logs from: Drawer → View Logs
class AppLogger {
  AppLogger._();

  static File? _logFile;
  static final List<String> _memoryBuffer = []; // last 500 lines in memory
  static const int _maxMemoryLines = 500;
  static const int _maxFileLines = 5000;

  /// Initialize logger. Call once at app startup.
  static Future<void> init() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      _logFile = File('${dir.path}/app_log.txt');

      // Create file if not exists
      if (!await _logFile!.exists()) {
        await _logFile!.create();
      }

      // Load last lines into memory buffer
      try {
        final content = await _logFile!.readAsString();
        final lines = content.split('\n').where((l) => l.isNotEmpty).toList();
        _memoryBuffer.addAll(lines.length > _maxMemoryLines
            ? lines.sublist(lines.length - _maxMemoryLines)
            : lines);
      } catch (_) {}

      info('App', 'Logger initialized');
    } catch (e) {
      debugPrint('[AppLogger] init failed: $e');
    }
  }

  /// Log info level message.
  static void info(String tag, String message) {
    _write('INFO', tag, message);
  }

  /// Log warning level message.
  static void warn(String tag, String message) {
    _write('WARN', tag, message);
  }

  /// Log error with optional exception.
  static void error(String tag, String message, [Object? error]) {
    final msg = error != null ? '$message | $error' : message;
    _write('ERROR', tag, msg);
  }

  /// Log strategy-specific events.
  static void strategy(String message) {
    _write('STRAT', 'Strategy', message);
  }

  /// Log trade events.
  static void trade(String message) {
    _write('TRADE', 'Trade', message);
  }

  static void _write(String level, String tag, String message) {
    final now = DateTime.now();
    final timestamp =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
    final date =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final line = '$date $timestamp [$level] $tag: $message';

    // Print to debug console
    debugPrint(line);

    // Add to memory buffer
    _memoryBuffer.add(line);
    if (_memoryBuffer.length > _maxMemoryLines) {
      _memoryBuffer.removeAt(0);
    }

    // Write to file (fire-and-forget)
    _appendToFile(line);
  }

  static Future<void> _appendToFile(String line) async {
    try {
      if (_logFile == null) return;
      await _logFile!.writeAsString('$line\n', mode: FileMode.append);

      // Trim file if too large
      final stat = await _logFile!.stat();
      if (stat.size > 500 * 1024) {
        // > 500KB
        await _trimFile();
      }
    } catch (_) {}
  }

  static Future<void> _trimFile() async {
    try {
      if (_logFile == null) return;
      final content = await _logFile!.readAsString();
      final lines = content.split('\n');
      if (lines.length > _maxFileLines) {
        final trimmed = lines.sublist(lines.length - _maxFileLines).join('\n');
        await _logFile!.writeAsString(trimmed);
      }
    } catch (_) {}
  }

  /// Get all log lines from memory buffer (most recent).
  static List<String> getRecentLogs() => List.unmodifiable(_memoryBuffer);

  /// Get full log file content.
  static Future<String> getFullLog() async {
    try {
      if (_logFile == null) return _memoryBuffer.join('\n');
      return await _logFile!.readAsString();
    } catch (_) {
      return _memoryBuffer.join('\n');
    }
  }

  /// Get log file path for sharing.
  static String? getLogFilePath() => _logFile?.path;

  /// Clear all logs.
  static Future<void> clear() async {
    _memoryBuffer.clear();
    try {
      if (_logFile != null) {
        await _logFile!.writeAsString('');
      }
    } catch (_) {}
    info('App', 'Logs cleared');
  }
}
