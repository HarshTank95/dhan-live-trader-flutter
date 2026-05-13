import 'package:flutter/material.dart';
import '../models/daily_run_summary_model.dart';
import '../services/run_logger.dart';
import '../services/storage_service.dart';
import 'run_log_detail_screen.dart';

class StrategyHistoryScreen extends StatefulWidget {
  final String? configId; // if null, show all configs

  const StrategyHistoryScreen({super.key, this.configId});

  @override
  State<StrategyHistoryScreen> createState() => _StrategyHistoryScreenState();
}

class _StrategyHistoryScreenState extends State<StrategyHistoryScreen> {
  List<DailyRunSummaryModel> _history = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    final all = await StorageService.loadDailyRunHistory();
    final filtered = widget.configId != null
        ? all.where((h) => h.configId == widget.configId).toList()
        : all;
    if (mounted) {
      setState(() {
        _history = filtered;
        _loading = false;
      });
    }
  }

  Future<void> _deleteRun(DailyRunSummaryModel run) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Run'),
        content: Text('Delete ${run.date} run history?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await StorageService.deleteDailyRun(run.date, run.configId);
      _loadHistory();
    }
  }

  Future<void> _clearAll() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear All History'),
        content: const Text('Delete all daily run history? This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear All', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await StorageService.clearAllDailyRunHistory();
      _loadHistory();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Run History'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          if (_history.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep),
              tooltip: 'Clear all history',
              onPressed: _clearAll,
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _history.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.history, size: 48, color: Colors.grey.shade300),
                      const SizedBox(height: 12),
                      const Text('No run history yet',
                          style: TextStyle(color: Colors.grey)),
                      const SizedBox(height: 4),
                      Text('History will appear after each strategy run',
                          style: TextStyle(color: Colors.grey.shade400, fontSize: 12)),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: _history.length,
                  itemBuilder: (context, i) => _buildRunCard(_history[i]),
                ),
    );
  }

  Widget _buildRunCard(DailyRunSummaryModel run) {
    final isProfit = run.totalPnl >= 0;
    final statusColor = run.status == 'completed'
        ? Colors.green
        : run.status == 'stopped'
            ? Colors.orange
            : Colors.red;
    final statusIcon = run.status == 'completed'
        ? Icons.check_circle
        : run.status == 'stopped'
            ? Icons.stop_circle
            : Icons.error;

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _showDetail(run),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header row: date + status + delete
              Row(
                children: [
                  Icon(statusIcon, size: 18, color: statusColor),
                  const SizedBox(width: 8),
                  Text(
                    run.date,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: run.paperTrading
                          ? Colors.orange.withValues(alpha: 0.15)
                          : Colors.green.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      run.paperTrading ? 'Paper' : 'Live',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: run.paperTrading ? Colors.orange : Colors.green,
                      ),
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.delete_outline, size: 20),
                    color: Colors.grey,
                    onPressed: () => _deleteRun(run),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              // Config name + time range
              Text(
                '${run.configName}  ${run.startTime} - ${run.endTime}',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
              ),
              const SizedBox(height: 10),
              // Stats row
              Row(
                children: [
                  _statBadge('Stocks', '${run.totalStocks}', Colors.blue),
                  const SizedBox(width: 6),
                  _statBadge('Candidates', '${run.effectiveCandidates}', Colors.orange),
                  const SizedBox(width: 6),
                  _statBadge('Trades', '${run.totalTrades}', Colors.teal),
                  const SizedBox(width: 6),
                  _statBadge(
                    'P&L',
                    'Rs ${run.totalPnl.toStringAsFixed(0)}',
                    isProfit ? Colors.green : Colors.red,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _statBadge(String label, String value, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          children: [
            Text(label, style: const TextStyle(fontSize: 9, color: Colors.grey)),
            const SizedBox(height: 2),
            Text(value,
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: color)),
          ],
        ),
      ),
    );
  }

  void _showDetail(DailyRunSummaryModel run) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        minChildSize: 0.3,
        maxChildSize: 0.9,
        expand: false,
        builder: (ctx, scrollController) {
          return Padding(
            padding: const EdgeInsets.all(16),
            child: ListView(
              controller: scrollController,
              children: [
                // Handle bar
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  '${run.date} — ${run.configName}',
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                Text(
                  '${run.paperTrading ? "Paper" : "Live"} | ${run.startTime} - ${run.endTime} | Status: ${run.status}',
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
                ),
                const SizedBox(height: 12),
                // Deep-link to per-run structured logs (RunLogger JSONL).
                // Older history entries from before this feature won't have
                // a file — the button hides itself in that case.
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    icon: const Icon(Icons.article_outlined, size: 18),
                    label: const Text('View full logs'),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      visualDensity: VisualDensity.compact,
                    ),
                    onPressed: () => _openRunLogs(run),
                  ),
                ),
                const SizedBox(height: 8),
                // Summary stats
                _detailRow('Total Stocks', '${run.totalStocks}'),
                _detailRow('Final Active', '${run.finalActiveStocks}'),
                _detailRow('Dominance Candidates', '${run.effectiveCandidates}'),
                _detailRow('Total Trades', '${run.totalTrades}'),
                _detailRow('Winners', '${run.winners}'),
                _detailRow('Losers', '${run.losers}'),
                _detailRow('Total P&L', 'Rs ${run.totalPnl.toStringAsFixed(2)}'),
                const SizedBox(height: 16),
                const Text('Activity Log',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                const Divider(),
                if (run.activityLog.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text('No activity recorded',
                        style: TextStyle(color: Colors.grey)),
                  )
                else
                  ...run.activityLog.map((event) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              event.contains('DOMINANCE')
                                  ? Icons.candlestick_chart
                                  : event.contains('TRADE')
                                      ? Icons.arrow_upward
                                      : event.contains('ERROR')
                                          ? Icons.error
                                          : event.contains('Eliminated')
                                              ? Icons.filter_alt
                                              : Icons.info_outline,
                              size: 14,
                              color: event.contains('DOMINANCE')
                                  ? Colors.orange
                                  : event.contains('TRADE')
                                      ? Colors.green
                                      : event.contains('ERROR')
                                          ? Colors.red
                                          : Colors.blue,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(event,
                                  style: const TextStyle(
                                      fontSize: 12, fontFamily: 'monospace')),
                            ),
                          ],
                        ),
                      )),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _openRunLogs(DailyRunSummaryModel run) async {
    final runId = RunLogger.makeRunId(run.date, run.configId);
    // Confirm the JSONL file actually exists before pushing; older runs
    // from before the per-run logger landed won't have one.
    final path = await RunLogger.runFilePath(runId);
    if (!mounted) return;
    if (path == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text(
                'No structured log saved for this run (predates the run logger).')),
      );
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => RunLogDetailScreen(runId: runId)),
    );
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(color: Colors.grey.shade600, fontSize: 13)),
          Text(value, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
        ],
      ),
    );
  }
}
