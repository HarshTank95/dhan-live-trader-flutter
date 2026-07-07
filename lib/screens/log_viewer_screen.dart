import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../services/app_logger.dart';
import '../services/run_logger.dart';
import '../services/storage_service.dart';
import 'run_log_detail_screen.dart';

/// Two-tab log viewer:
///   * **App**  — flat rolling `app_log.txt` (general events, network, UI).
///   * **Runs** — per-strategy-run JSONL files for forensic debugging.
class LogViewerScreen extends StatefulWidget {
  const LogViewerScreen({super.key});

  @override
  State<LogViewerScreen> createState() => _LogViewerScreenState();
}

class _LogViewerScreenState extends State<LogViewerScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Logs'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        bottom: TabBar(
          controller: _tab,
          tabs: const [
            Tab(icon: Icon(Icons.list_alt), text: 'App'),
            Tab(icon: Icon(Icons.history), text: 'Runs'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tab,
        children: const [
          _AppLogTab(),
          _RunsTab(),
        ],
      ),
    );
  }
}

// ── App log tab — preserves the previous flat-log behavior ────────────────

class _AppLogTab extends StatefulWidget {
  const _AppLogTab();

  @override
  State<_AppLogTab> createState() => _AppLogTabState();
}

class _AppLogTabState extends State<_AppLogTab> {
  List<String> _logs = [];
  String _filter = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    setState(() {
      _logs = AppLogger.getRecentLogs().reversed.toList(); // newest first
    });
  }

  List<String> get _filteredLogs {
    if (_filter.isEmpty) return _logs;
    final q = _filter.toLowerCase();
    return _logs.where((l) => l.toLowerCase().contains(q)).toList();
  }

  Future<void> _copyAll() async {
    final logs = _filteredLogs;
    final text = logs.join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      final label = _filter.isEmpty ? 'All' : _filter;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${logs.length} logs copied ($label)')),
      );
    }
  }

  Future<void> _shareLogs() async {
    try {
      final logs = _filteredLogs;
      if (logs.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No logs to share')),
          );
        }
        return;
      }
      final dir = await getTemporaryDirectory();
      final now = DateTime.now();
      final fileName =
          'dhan_logs_${now.year}${now.month.toString().padLeft(2, "0")}${now.day.toString().padLeft(2, "0")}_${now.hour.toString().padLeft(2, "0")}${now.minute.toString().padLeft(2, "0")}.txt';
      final file = File('${dir.path}/$fileName');
      await file.writeAsString(logs.join('\n'));
      await Share.shareXFiles(
        [XFile(file.path)],
        subject:
            'Dhan App Logs - ${now.year}-${now.month.toString().padLeft(2, "0")}-${now.day.toString().padLeft(2, "0")}',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Share failed: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _clearLogs() async {
    await AppLogger.clear();
    _load();
  }

  Color _levelColor(String line) {
    if (line.contains('[ERROR]')) return Colors.red;
    if (line.contains('[WARN]')) return Colors.orange;
    if (line.contains('[STRAT]')) return Colors.blue;
    if (line.contains('[TRADE]')) return Colors.green;
    return Colors.grey.shade400;
  }

  @override
  Widget build(BuildContext context) {
    final logs = _filteredLogs;
    return Column(
      children: [
        // Action row
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
          child: Row(
            children: [
              Text('${logs.length} entries',
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.share, size: 20),
                tooltip: 'Share',
                onPressed: _shareLogs,
              ),
              IconButton(
                icon: const Icon(Icons.copy, size: 20),
                tooltip: 'Copy filtered',
                onPressed: _copyAll,
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 20),
                tooltip: 'Clear',
                onPressed: _clearLogs,
              ),
              IconButton(
                icon: const Icon(Icons.refresh, size: 20),
                tooltip: 'Refresh',
                onPressed: _load,
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
          child: TextField(
            decoration: InputDecoration(
              hintText: 'Filter logs… (e.g. ERROR, Strategy, Trade)',
              prefixIcon: const Icon(Icons.search, size: 20),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 10),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            onChanged: (v) => setState(() => _filter = v),
          ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              _chip('All', ''),
              _chip('Errors', 'ERROR'),
              _chip('Strategy', 'STRAT'),
              _chip('Trade', 'TRADE'),
              _chip('Warn', 'WARN'),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Expanded(
          child: logs.isEmpty
              ? const Center(
                  child: Text('No logs', style: TextStyle(color: Colors.grey)))
              : ListView.builder(
                  itemCount: logs.length,
                  itemBuilder: (_, i) {
                    final line = logs[i];
                    return Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        border: Border(
                          left: BorderSide(
                            color: _levelColor(line),
                            width: 3,
                          ),
                        ),
                      ),
                      child: Text(
                        line,
                        style: TextStyle(
                          fontSize: 11,
                          fontFamily: 'monospace',
                          color: line.contains('[ERROR]')
                              ? Colors.red.shade300
                              : null,
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _chip(String label, String value) {
    final isActive = _filter == value;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ChoiceChip(
        label: Text(label, style: const TextStyle(fontSize: 12)),
        selected: isActive,
        onSelected: (_) => setState(() => _filter = value),
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}

// ── Runs tab — list of strategy run JSONL files ───────────────────────────

class _RunsTab extends StatefulWidget {
  const _RunsTab();

  @override
  State<_RunsTab> createState() => _RunsTabState();
}

class _RunsTabState extends State<_RunsTab> {
  List<RunLogIndex> _runs = [];
  bool _loading = true;
  int _retentionDays = 14;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final runs = await RunLogger.listRuns();
    final days = await StorageService.getLogRetentionDays();
    if (!mounted) return;
    setState(() {
      _runs = runs;
      _retentionDays = days;
      _loading = false;
    });
  }

  Future<void> _changeRetention() async {
    final picked = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Keep run logs for…'),
        children: [
          for (final d in [7, 14, 30, 60])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, d),
              child: Text('$d days${d == _retentionDays ? "  ✓" : ""}'),
            ),
        ],
      ),
    );
    if (picked == null) return;
    await StorageService.setLogRetentionDays(picked);
    final removed = await RunLogger.cleanup(retentionDays: picked);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text(
              'Retention set to $picked days${removed > 0 ? " — pruned $removed old run(s)" : ""}')),
    );
    _load();
  }

  Future<void> _deleteAll() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete all run logs?'),
        content: const Text(
            'This removes every per-run log file. The general app log is not affected.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete all',
                style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    final n = await RunLogger.deleteAll();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Deleted $n run log(s)')),
    );
    _load();
  }

  Future<void> _deleteOne(RunLogIndex r) async {
    await RunLogger.deleteRun(r.runId);
    _load();
  }

  void _open(RunLogIndex r) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => RunLogDetailScreen(runId: r.runId)),
    ).then((_) => _load());
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Row(
            children: [
              Text('${_runs.length} run(s) — retention $_retentionDays days',
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.timer_outlined, size: 20),
                tooltip: 'Retention',
                onPressed: _changeRetention,
              ),
              if (_runs.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.delete_sweep, size: 20),
                  tooltip: 'Delete all',
                  onPressed: _deleteAll,
                ),
              IconButton(
                icon: const Icon(Icons.refresh, size: 20),
                tooltip: 'Refresh',
                onPressed: _load,
              ),
            ],
          ),
        ),
        Expanded(
          child: _runs.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.history, size: 48, color: Colors.grey.shade300),
                      const SizedBox(height: 12),
                      const Text('No run logs yet',
                          style: TextStyle(color: Colors.grey)),
                      const SizedBox(height: 4),
                      Text('Each strategy run produces a structured log here',
                          style: TextStyle(
                              color: Colors.grey.shade400, fontSize: 12)),
                    ],
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(12),
                  itemCount: _runs.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (_, i) => _RunCard(
                    run: _runs[i],
                    onTap: () => _open(_runs[i]),
                    onDelete: () => _deleteOne(_runs[i]),
                  ),
                ),
        ),
      ],
    );
  }
}

class _RunCard extends StatelessWidget {
  final RunLogIndex run;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _RunCard({
    required this.run,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final statusColor = run.status == 'completed'
        ? Colors.green
        : run.status == 'running'
            ? Colors.blue
            : run.status == 'stopped'
                ? Colors.orange
                : Colors.red;
    final statusIcon = run.status == 'completed'
        ? Icons.check_circle
        : run.status == 'running'
            ? Icons.play_circle
            : run.status == 'stopped'
                ? Icons.stop_circle
                : Icons.error;

    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      margin: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(statusIcon, size: 18, color: statusColor),
                  const SizedBox(width: 8),
                  Text(run.date,
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.bold)),
                  const SizedBox(width: 8),
                  _kindChip(run),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.delete_outline, size: 18),
                    color: Colors.grey,
                    onPressed: onDelete,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '${run.configName} • ${run.startTime}'
                '${run.endTime.isNotEmpty ? " → ${run.endTime}" : ""}',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
              ),
              // Interrupted backtest (cancel / network / crash): show the
              // resume checkpoint — the last fully-simulated date — so the
              // user re-runs only the remaining range.
              if (run.kind == 'backtest' &&
                  run.status != 'completed' &&
                  run.lastSimDate.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  '⏸ simulated through ${run.lastSimDate} — resume from the next day',
                  style: const TextStyle(
                      fontSize: 12,
                      color: Colors.orange,
                      fontWeight: FontWeight.w600),
                ),
              ],
              const SizedBox(height: 8),
              Row(
                children: [
                  _stat('Stocks', '${run.totalStocks}', Colors.blue),
                  const SizedBox(width: 6),
                  _stat('Signals', '${run.signals}', Colors.orange),
                  const SizedBox(width: 6),
                  _stat('Trades', '${run.trades}', Colors.teal),
                  const SizedBox(width: 6),
                  _stat(
                    'P&L',
                    'Rs ${run.totalPnl.toStringAsFixed(0)}',
                    run.totalPnl >= 0 ? Colors.green : Colors.red,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _kindChip(RunLogIndex r) {
    // Backtest runs get a purple "Backtest" chip; live runs keep the existing
    // Paper/Live distinction.
    final (label, color) = r.kind == 'backtest'
        ? ('Backtest', Colors.purple)
        : r.paperTrading
            ? ('Paper', Colors.orange)
            : ('Live', Colors.green);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }

  Widget _stat(String label, String value, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          children: [
            Text(label,
                style: const TextStyle(fontSize: 9, color: Colors.grey)),
            const SizedBox(height: 2),
            Text(value,
                style: TextStyle(
                    fontSize: 11, fontWeight: FontWeight.bold, color: color)),
          ],
        ),
      ),
    );
  }
}
