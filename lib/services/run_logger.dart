import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'app_logger.dart';

/// Structured per-run logger.
///
/// Each strategy engine run writes a JSONL file under
/// `{appDocs}/strategy_logs/{date}_{configIdShort}.jsonl` plus a sibling
/// `.meta.json` describing the run. The Log Viewer screen reads these to give
/// developers a forensic trail of any past run, even after the rolling
/// `app_log.txt` has cycled past it.
///
/// JSONL line format:
/// ```
/// {"t":"2026-05-12T09:35:05.123","lvl":"info","tag":"Scan","msg":"...","data":{...}}
/// ```
class RunLogger {
  RunLogger._();

  static const _subdir = 'strategy_logs';

  /// Compose a stable runId from date + configId. Keeps the filename short
  /// while still uniquely identifying the run.
  static String makeRunId(String date, String configId) {
    final short = configId.length > 8 ? configId.substring(0, 8) : configId;
    final safeDate = date.replaceAll(RegExp(r'[^0-9-]'), '');
    final safeShort = short.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '');
    return '${safeDate}_$safeShort';
  }

  static Future<Directory> _runsDir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/$_subdir');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Open a new logging session for an engine run. Caller is expected to
  /// dispose by calling [RunLoggerSession.close] when the run ends.
  ///
  /// [kind] distinguishes `'live'` engine runs from `'backtest'` simulations
  /// — surfaced in the Runs tab so the same screen can list both with a
  /// clear visual marker.
  static Future<RunLoggerSession> startRun({
    required String runId,
    required String date,
    required String configId,
    required String configName,
    required String strategyType,
    required bool paperTrading,
    required String startTime,
    String kind = 'live',
  }) async {
    try {
      final dir = await _runsDir();
      final jsonlPath = '${dir.path}/$runId.jsonl';
      final metaPath = '${dir.path}/$runId.meta.json';

      final jsonlFile = File(jsonlPath);
      if (!await jsonlFile.exists()) {
        await jsonlFile.create();
      }
      // One IOSink per run, opened in append mode. All emits stream through
      // this single handle so high-volume per-stock REJECT events can't race
      // each other and drop writes (the previous per-event writeAsString
      // pattern lost ~99% of REJECT events under load).
      final sink = jsonlFile.openWrite(mode: FileMode.append);

      final meta = <String, dynamic>{
        'runId': runId,
        'date': date,
        'kind': kind,
        'configId': configId,
        'configName': configName,
        'strategyType': strategyType,
        'paperTrading': paperTrading,
        'startTime': startTime,
        'endTime': '',
        'status': 'running',
        'signals': 0,
        'trades': 0,
        'totalStocks': 0,
        'finalActiveStocks': 0,
        'totalPnl': 0.0,
      };
      await File(metaPath).writeAsString(jsonEncode(meta));

      return RunLoggerSession._(
        runId: runId,
        sink: sink,
        metaFile: File(metaPath),
        meta: meta,
      );
    } catch (e) {
      debugPrint('[RunLogger] startRun failed: $e');
      return RunLoggerSession._disabled(runId);
    }
  }

  /// Return all known run summaries (newest first) by reading meta files.
  static Future<List<RunLogIndex>> listRuns() async {
    try {
      final dir = await _runsDir();
      final entries = await dir.list().toList();
      final out = <RunLogIndex>[];
      for (final ent in entries) {
        if (ent is! File) continue;
        if (!ent.path.endsWith('.meta.json')) continue;
        try {
          final raw = await ent.readAsString();
          final m = jsonDecode(raw) as Map<String, dynamic>;
          out.add(RunLogIndex.fromJson(m));
        } catch (_) {
          // Skip corrupt meta file
        }
      }
      out.sort((a, b) {
        final byDate = b.date.compareTo(a.date);
        if (byDate != 0) return byDate;
        return b.startTime.compareTo(a.startTime);
      });
      return out;
    } catch (_) {
      return [];
    }
  }

  /// Read all JSONL events for a given run.
  static Future<List<RunLogEvent>> readRun(String runId) async {
    try {
      final dir = await _runsDir();
      final file = File('${dir.path}/$runId.jsonl');
      if (!await file.exists()) return [];
      final content = await file.readAsString();
      final lines = content.split('\n');
      final out = <RunLogEvent>[];
      for (final line in lines) {
        if (line.isEmpty) continue;
        try {
          final m = jsonDecode(line) as Map<String, dynamic>;
          out.add(RunLogEvent.fromJson(m));
        } catch (_) {
          // Skip malformed line
        }
      }
      return out;
    } catch (_) {
      return [];
    }
  }

  /// Return the path of a run's JSONL file (for share-as-attachment).
  static Future<String?> runFilePath(String runId) async {
    try {
      final dir = await _runsDir();
      final file = File('${dir.path}/$runId.jsonl');
      if (!await file.exists()) return null;
      return file.path;
    } catch (_) {
      return null;
    }
  }

  /// Delete one run (both JSONL and meta files).
  static Future<void> deleteRun(String runId) async {
    try {
      final dir = await _runsDir();
      final jsonl = File('${dir.path}/$runId.jsonl');
      final meta = File('${dir.path}/$runId.meta.json');
      if (await jsonl.exists()) await jsonl.delete();
      if (await meta.exists()) await meta.delete();
    } catch (e) {
      debugPrint('[RunLogger] deleteRun failed: $e');
    }
  }

  /// Delete runs whose date is older than (today - [retentionDays]).
  /// Returns count of deleted runs. Quiet on failure.
  static Future<int> cleanup({required int retentionDays}) async {
    if (retentionDays <= 0) return 0;
    try {
      final cutoff = DateTime.now().subtract(Duration(days: retentionDays));
      final cutoffStr =
          '${cutoff.year}-${cutoff.month.toString().padLeft(2, "0")}-${cutoff.day.toString().padLeft(2, "0")}';
      final runs = await listRuns();
      int deleted = 0;
      for (final r in runs) {
        if (r.date.compareTo(cutoffStr) < 0) {
          await deleteRun(r.runId);
          deleted++;
        }
      }
      if (deleted > 0) {
        AppLogger.info(
            'RunLogger', 'Retention sweep: deleted $deleted run(s) older than $cutoffStr');
      }
      return deleted;
    } catch (e) {
      debugPrint('[RunLogger] cleanup failed: $e');
      return 0;
    }
  }

  /// Delete all run log files (used by Clear All action).
  static Future<int> deleteAll() async {
    try {
      final runs = await listRuns();
      for (final r in runs) {
        await deleteRun(r.runId);
      }
      return runs.length;
    } catch (_) {
      return 0;
    }
  }
}

/// An open per-run logger. Holds a single [IOSink] for append-only writes
/// and a meta file that gets rewritten on each [updateMeta]/[close].
///
/// The sink-per-session design is important: the dominance strategy can fire
/// thousands of per-stock REJECT events per scan slot. A previous implementation
/// did `unawaited(writeAsString(append))` per event — those concurrent file
/// opens raced each other and silently dropped most writes. With a single sink
/// every event is serialised through the same handle in arrival order.
class RunLoggerSession {
  final String runId;
  final IOSink? _sink;
  final File? _metaFile;
  final Map<String, dynamic> _meta;
  final bool _disabled;

  RunLoggerSession._({
    required this.runId,
    required IOSink sink,
    required File metaFile,
    required Map<String, dynamic> meta,
  })  : _sink = sink,
        _metaFile = metaFile,
        _meta = meta,
        _disabled = false;

  RunLoggerSession._disabled(this.runId)
      : _sink = null,
        _metaFile = null,
        _meta = {},
        _disabled = true;

  void info(String tag, String msg, [Map<String, dynamic>? data]) =>
      _emit('info', tag, msg, data);

  void warn(String tag, String msg, [Map<String, dynamic>? data]) =>
      _emit('warn', tag, msg, data);

  void error(String tag, String msg, [Map<String, dynamic>? data]) =>
      _emit('error', tag, msg, data);

  void _emit(
      String level, String tag, String msg, Map<String, dynamic>? data) {
    if (_disabled || _sink == null) return;
    try {
      final ev = <String, dynamic>{
        't': DateTime.now().toIso8601String(),
        'lvl': level,
        'tag': tag,
        'msg': msg,
      };
      if (data != null && data.isNotEmpty) {
        ev['data'] = data;
      }
      _sink.writeln(jsonEncode(ev));
    } catch (e) {
      debugPrint('[RunLogger] _emit failed: $e');
    }
  }

  /// Update meta fields (totalStocks, signals, trades, etc.). Caller can pass
  /// any subset; missing keys are preserved.
  Future<void> updateMeta(Map<String, dynamic> patch) async {
    if (_disabled || _metaFile == null) return;
    try {
      _meta.addAll(patch);
      await _metaFile.writeAsString(jsonEncode(_meta));
    } catch (e) {
      debugPrint('[RunLogger] updateMeta failed: $e');
    }
  }

  /// Finalize the run. Sets endTime and status, persists final meta and
  /// flushes/closes the JSONL sink.
  Future<void> close({
    required String status,
    required String endTime,
    int? signals,
    int? trades,
    int? totalStocks,
    int? finalActiveStocks,
    double? totalPnl,
  }) async {
    final patch = <String, dynamic>{
      'status': status,
      'endTime': endTime,
    };
    if (signals != null) patch['signals'] = signals;
    if (trades != null) patch['trades'] = trades;
    if (totalStocks != null) patch['totalStocks'] = totalStocks;
    if (finalActiveStocks != null) patch['finalActiveStocks'] = finalActiveStocks;
    if (totalPnl != null) patch['totalPnl'] = totalPnl;
    await updateMeta(patch);
    try {
      await _sink?.flush();
      await _sink?.close();
    } catch (e) {
      debugPrint('[RunLogger] close sink failed: $e');
    }
  }
}

/// Summary of a single run, parsed from a `.meta.json` file.
class RunLogIndex {
  final String runId;
  final String date;
  final String kind; // 'live' | 'backtest'
  final String configId;
  final String configName;
  final String strategyType;
  final bool paperTrading;
  final String startTime;
  final String endTime;
  final String status;
  final int signals;
  final int trades;
  final int totalStocks;
  final int finalActiveStocks;
  final double totalPnl;

  RunLogIndex({
    required this.runId,
    required this.date,
    required this.kind,
    required this.configId,
    required this.configName,
    required this.strategyType,
    required this.paperTrading,
    required this.startTime,
    required this.endTime,
    required this.status,
    required this.signals,
    required this.trades,
    required this.totalStocks,
    required this.finalActiveStocks,
    required this.totalPnl,
  });

  factory RunLogIndex.fromJson(Map<String, dynamic> m) => RunLogIndex(
        runId: m['runId'] as String? ?? '',
        date: m['date'] as String? ?? '',
        kind: m['kind'] as String? ?? 'live',
        configId: m['configId'] as String? ?? '',
        configName: m['configName'] as String? ?? '',
        strategyType: m['strategyType'] as String? ?? '',
        paperTrading: m['paperTrading'] as bool? ?? true,
        startTime: m['startTime'] as String? ?? '',
        endTime: m['endTime'] as String? ?? '',
        status: m['status'] as String? ?? '',
        signals: (m['signals'] as num?)?.toInt() ?? 0,
        trades: (m['trades'] as num?)?.toInt() ?? 0,
        totalStocks: (m['totalStocks'] as num?)?.toInt() ?? 0,
        finalActiveStocks: (m['finalActiveStocks'] as num?)?.toInt() ?? 0,
        totalPnl: (m['totalPnl'] as num?)?.toDouble() ?? 0,
      );
}

/// Single line from a `.jsonl` file.
class RunLogEvent {
  final DateTime timestamp;
  final String level; // info | warn | error
  final String tag;
  final String message;
  final Map<String, dynamic>? data;

  RunLogEvent({
    required this.timestamp,
    required this.level,
    required this.tag,
    required this.message,
    this.data,
  });

  factory RunLogEvent.fromJson(Map<String, dynamic> m) => RunLogEvent(
        timestamp: DateTime.tryParse(m['t'] as String? ?? '') ?? DateTime.now(),
        level: m['lvl'] as String? ?? 'info',
        tag: m['tag'] as String? ?? '',
        message: m['msg'] as String? ?? '',
        data: m['data'] as Map<String, dynamic>?,
      );
}
