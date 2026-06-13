import 'package:flutter/material.dart';
import '../models/backtest_result_model.dart';
import '../services/storage_service.dart';
import 'backtest_results_screen.dart';

/// Browsable history of past backtest runs (newest first).
///
/// Results have always been persisted by the engine ([StorageService] keeps
/// the most recent 20) but were only reachable on the results page right
/// after a run. This screen lists them permanently: tap a card for the full
/// day-by-day results grid, swipe (or use the menu) to delete.
class BacktestHistoryScreen extends StatefulWidget {
  const BacktestHistoryScreen({super.key});

  @override
  State<BacktestHistoryScreen> createState() => _BacktestHistoryScreenState();
}

class _BacktestHistoryScreenState extends State<BacktestHistoryScreen> {
  List<BacktestResultModel> _results = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final results = await StorageService.loadBacktestResults();
    if (!mounted) return;
    setState(() {
      _results = results;
      _loading = false;
    });
  }

  Future<void> _delete(BacktestResultModel r) async {
    await StorageService.deleteBacktestResult(r.id);
    await _load();
  }

  Future<void> _clearAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear All History?'),
        content: Text(
            'Delete all ${_results.length} saved backtest result(s)? This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child:
                  const Text('Delete All', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (confirmed == true) {
      await StorageService.clearAllBacktestResults();
      await _load();
    }
  }

  String _fmtDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  String _fmtRunAt(DateTime d) =>
      '${_fmtDate(d)} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Backtest History'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          if (_results.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep_outlined),
              tooltip: 'Clear all',
              onPressed: _clearAll,
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _results.isEmpty
              ? _buildEmpty()
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: _results.length,
                    itemBuilder: (context, i) => _buildCard(_results[i]),
                  ),
                ),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.history, size: 64, color: Colors.grey.shade400),
          const SizedBox(height: 16),
          const Text('No backtest runs yet',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          const Text(
            'Run a backtest from a strategy\'s ⋮ menu —\nresults will appear here.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey),
          ),
        ],
      ),
    );
  }

  Widget _buildCard(BacktestResultModel r) {
    final winRate =
        r.totalTrades > 0 ? r.wins * 100 / r.totalTrades : 0.0;
    final pnlColor = r.totalPnl > 0
        ? Colors.green
        : r.totalPnl < 0
            ? Colors.red
            : Colors.grey;

    return Dismissible(
      key: ValueKey(r.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        color: Colors.red,
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      confirmDismiss: (_) async {
        return await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('Delete this run?'),
                content: Text(
                    '${r.strategyName}\n${_fmtDate(r.fromDate)} → ${_fmtDate(r.toDate)}'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('Cancel')),
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('Delete',
                          style: TextStyle(color: Colors.red))),
                ],
              ),
            ) ??
            false;
      },
      onDismissed: (_) => _delete(r),
      child: Card(
        margin: const EdgeInsets.only(bottom: 12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
                builder: (_) => BacktestResultsScreen(result: r)),
          ),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header: strategy + net P&L
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        r.strategyName,
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.bold),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      '${r.totalPnl >= 0 ? "+" : ""}₹${r.totalPnl.toStringAsFixed(0)}',
                      style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: pnlColor),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  '${_fmtDate(r.fromDate)} → ${_fmtDate(r.toDate)}  ·  ${r.stockUniverseLabel}',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
                const SizedBox(height: 10),
                // Stats row
                Row(
                  children: [
                    _stat('Trades', '${r.totalTrades}'),
                    _stat('Win rate',
                        r.totalTrades > 0 ? '${winRate.toStringAsFixed(0)}%' : '—'),
                    _stat('W / L', '${r.wins} / ${r.losses}'),
                    _stat('Days', '${r.totalTradingDays}'),
                    _stat('Max DD', '₹${r.maxDrawdown.toStringAsFixed(0)}'),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Run ${_fmtRunAt(r.runAt)}  ·  ${r.durationSeconds}s',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _stat(String label, String value) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(fontSize: 10, color: Colors.grey.shade500)),
          const SizedBox(height: 2),
          Text(value,
              style:
                  const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}
