import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../models/backtest_result_model.dart';
import '../models/strategy_trade_model.dart';

class BacktestResultsScreen extends StatelessWidget {
  final BacktestResultModel result;

  const BacktestResultsScreen({super.key, required this.result});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Backtest Results'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Summary'),
              Tab(text: 'Daily'),
              Tab(text: 'Trades'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _SummaryTab(result: result),
            _DailyTab(result: result),
            _TradesTab(result: result),
          ],
        ),
      ),
    );
  }
}

// ── Summary Tab ─────────────────────────────────────────────────────────

class _SummaryTab extends StatelessWidget {
  final BacktestResultModel result;
  const _SummaryTab({required this.result});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isProfit = result.totalPnl >= 0;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // P&L Hero Card
        Card(
          color: isProfit ? Colors.green.shade900 : Colors.red.shade900,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                Text(
                  isProfit ? 'Net Profit' : 'Net Loss',
                  style: const TextStyle(color: Colors.white70, fontSize: 14),
                ),
                const SizedBox(height: 4),
                Text(
                  '${isProfit ? "+" : ""}₹${result.totalPnl.toStringAsFixed(0)}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 36,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '${result.strategyName} • ${result.stockUniverseLabel} • '
                  '${result.totalTradingDays} days',
                  style: const TextStyle(color: Colors.white60, fontSize: 12),
                ),
              ],
            ),
          ),
        ),

        const SizedBox(height: 16),

        // Key Metrics Grid
        _MetricsGrid(result: result),

        const SizedBox(height: 16),

        // Equity Curve
        if (result.equityCurve.isNotEmpty) ...[
          Text('Equity Curve',
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          SizedBox(
            height: 200,
            child: _EquityCurveChart(curve: result.equityCurve),
          ),
        ],

        const SizedBox(height: 16),

        // Backtest Info
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Backtest Info',
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                _infoRow('Period',
                    '${_fmtDate(result.fromDate)} → ${_fmtDate(result.toDate)}'),
                _infoRow('Universe',
                    '${result.stockUniverseLabel} (${result.stockUniverseSize} stocks)'),
                _infoRow('Run time', '${result.durationSeconds}s'),
                _infoRow('Run at', _fmtDateTime(result.runAt)),
                _infoRow(
                    'Risk/Trade', '₹${(result.params['fixedStopLoss'] ?? 500)}'),
                _infoRow(
                    'Target/Trade', '₹${(result.params['fixedTarget'] ?? 2000)}'),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Colors.grey)),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }

  String _fmtDate(DateTime d) =>
      '${d.day}/${d.month}/${d.year}';

  String _fmtDateTime(DateTime d) =>
      '${d.day}/${d.month}/${d.year} ${d.hour}:${d.minute.toString().padLeft(2, '0')}';
}

// ── Metrics Grid ────────────────────────────────────────────────────────

class _MetricsGrid extends StatelessWidget {
  final BacktestResultModel result;
  const _MetricsGrid({required this.result});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _metricCard('Total Trades', '${result.totalTrades}', Colors.blue),
        _metricCard('Win Rate', '${result.winRate.toStringAsFixed(1)}%',
            result.winRate >= 50 ? Colors.green : Colors.orange),
        _metricCard('Wins', '${result.wins}', Colors.green),
        _metricCard('Losses', '${result.losses}', Colors.red),
        _metricCard('Profit Factor', result.profitFactor.isFinite
            ? result.profitFactor.toStringAsFixed(2)
            : '∞', Colors.blue),
        _metricCard('Max Drawdown', '₹${result.maxDrawdown.toStringAsFixed(0)}',
            Colors.orange),
        _metricCard('Avg P&L/Trade',
            '₹${result.avgPnlPerTrade.toStringAsFixed(0)}', Colors.purple),
        _metricCard('Signals', '${result.totalSignals}', Colors.teal),
        _metricCard('Days w/ Signals', '${result.daysWithSignals}', Colors.teal),
        _metricCard('Days w/ Trades', '${result.daysWithTrades}', Colors.teal),
      ],
    );
  }

  Widget _metricCard(String label, String value, Color color) {
    return SizedBox(
      width: 110,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            children: [
              Text(value,
                  style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: color)),
              const SizedBox(height: 2),
              Text(label,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 10, color: Colors.grey)),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Equity Curve Chart ──────────────────────────────────────────────────

class _EquityCurveChart extends StatelessWidget {
  final List<double> curve;
  const _EquityCurveChart({required this.curve});

  @override
  Widget build(BuildContext context) {
    if (curve.isEmpty) return const SizedBox();

    final spots = <FlSpot>[];
    for (int i = 0; i < curve.length; i++) {
      spots.add(FlSpot(i.toDouble(), curve[i]));
    }

    final maxY = curve.reduce((a, b) => a > b ? a : b);
    final minY = curve.reduce((a, b) => a < b ? a : b);
    final range = (maxY - minY).abs();
    final padding = range * 0.1;

    return LineChart(
      LineChartData(
        gridData: const FlGridData(show: true, drawVerticalLine: false),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          bottomTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 50,
              getTitlesWidget: (value, meta) => Text(
                '₹${value.toStringAsFixed(0)}',
                style: const TextStyle(fontSize: 10),
              ),
            ),
          ),
        ),
        borderData: FlBorderData(show: false),
        minY: minY - padding,
        maxY: maxY + padding,
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: true,
            curveSmoothness: 0.2,
            color: curve.last >= 0 ? Colors.green : Colors.red,
            barWidth: 2,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(
              show: true,
              color: (curve.last >= 0 ? Colors.green : Colors.red)
                  .withValues(alpha: 0.1),
            ),
          ),
        ],
        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
            getTooltipItems: (spots) => spots.map((spot) {
              return LineTooltipItem(
                'Day ${spot.x.toInt() + 1}\n₹${spot.y.toStringAsFixed(0)}',
                const TextStyle(fontSize: 12, color: Colors.white),
              );
            }).toList(),
          ),
        ),
      ),
    );
  }
}

// ── Daily Tab ───────────────────────────────────────────────────────────

class _DailyTab extends StatelessWidget {
  final BacktestResultModel result;
  const _DailyTab({required this.result});

  @override
  Widget build(BuildContext context) {
    if (result.dayResults.isEmpty) {
      return const Center(child: Text('No trading days'));
    }

    return ListView.builder(
      padding: const EdgeInsets.all(8),
      itemCount: result.dayResults.length,
      itemBuilder: (context, i) {
        final day = result.dayResults[i];
        final isProfit = day.dayPnl >= 0;

        return Card(
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor:
                  day.tradesEntered > 0
                      ? (isProfit ? Colors.green : Colors.red)
                      : Colors.grey,
              radius: 18,
              child: Text(
                day.tradesEntered > 0
                    ? '${isProfit ? "+" : ""}${day.dayPnl.toStringAsFixed(0)}'
                    : '—',
                style: const TextStyle(color: Colors.white, fontSize: 10),
              ),
            ),
            title: Text(day.date,
                style: const TextStyle(fontWeight: FontWeight.bold)),
            subtitle: Text(
              '${day.stocksScanned} scanned → ${day.stocksAfterElimination} survived → '
              '${day.dominanceSignals} signals → ${day.tradesEntered} trades',
              style: const TextStyle(fontSize: 11),
            ),
            trailing: day.tradesEntered > 0
                ? Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        '₹${day.dayPnl.toStringAsFixed(0)}',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: isProfit ? Colors.green : Colors.red,
                        ),
                      ),
                      Text(
                        'W:${day.wins} L:${day.losses}',
                        style:
                            const TextStyle(fontSize: 11, color: Colors.grey),
                      ),
                    ],
                  )
                : const Text('No trades',
                    style: TextStyle(color: Colors.grey, fontSize: 12)),
            onTap: day.trades.isNotEmpty
                ? () => _showDayDetail(context, day)
                : null,
          ),
        );
      },
    );
  }

  void _showDayDetail(BuildContext context, BacktestDayResult day) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.5,
        maxChildSize: 0.9,
        builder: (context, scrollController) {
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  '${day.date} — Trades',
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ),
              Expanded(
                child: ListView.builder(
                  controller: scrollController,
                  itemCount: day.trades.length,
                  itemBuilder: (_, i) {
                    final trade = day.trades[i];
                    final isWin = trade.pnl > 0;
                    final entryTimeStr = trade.entryTime != null
                        ? '${trade.entryTime!.hour}:${trade.entryTime!.minute.toString().padLeft(2, '0')}'
                        : '?';
                    final exitTimeStr = trade.exitTime != null
                        ? '${trade.exitTime!.hour}:${trade.exitTime!.minute.toString().padLeft(2, '0')}'
                        : '?';
                    return ListTile(
                      leading: Icon(
                        trade.outcome == TradeOutcome.target
                            ? Icons.check_circle
                            : trade.outcome == TradeOutcome.stopLoss
                                ? Icons.cancel
                                : Icons.schedule,
                        color: isWin
                            ? Colors.green
                            : trade.pnl < 0
                                ? Colors.red
                                : Colors.grey,
                      ),
                      title: Text(trade.symbol,
                          style:
                              const TextStyle(fontWeight: FontWeight.bold)),
                      subtitle: Text(
                        'Entry: ₹${trade.entryPrice.toStringAsFixed(1)} @ $entryTimeStr → '
                        'Exit: ₹${trade.exitPrice?.toStringAsFixed(1) ?? "?"} @ $exitTimeStr '
                        '(${trade.outcome.name})\n'
                        'Qty: ${trade.quantity} | SL: ₹${trade.stopLoss.toStringAsFixed(1)} | '
                        'Target: ₹${trade.target.toStringAsFixed(1)}',
                        style: const TextStyle(fontSize: 11),
                      ),
                      trailing: Text(
                        '${isWin ? "+" : ""}₹${trade.pnl.toStringAsFixed(0)}',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: isWin ? Colors.green : Colors.red,
                        ),
                      ),
                      isThreeLine: true,
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ── Trades Tab ──────────────────────────────────────────────────────────

class _TradesTab extends StatelessWidget {
  final BacktestResultModel result;
  const _TradesTab({required this.result});

  @override
  Widget build(BuildContext context) {
    final allTrades = <StrategyTradeModel>[];
    for (final day in result.dayResults) {
      allTrades.addAll(day.trades);
    }

    if (allTrades.isEmpty) {
      return const Center(child: Text('No trades executed'));
    }

    return ListView.builder(
      padding: const EdgeInsets.all(8),
      itemCount: allTrades.length,
      itemBuilder: (context, i) {
        final trade = allTrades[i];
        final isWin = trade.pnl > 0;
        final entryTimeStr = trade.entryTime != null
            ? '${trade.entryTime!.hour}:${trade.entryTime!.minute.toString().padLeft(2, '0')}'
            : '?';
        final exitTimeStr = trade.exitTime != null
            ? '${trade.exitTime!.hour}:${trade.exitTime!.minute.toString().padLeft(2, '0')}'
            : '?';

        return Card(
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: isWin ? Colors.green : Colors.red,
              radius: 16,
              child: Text(
                '${i + 1}',
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ),
            title: Row(
              children: [
                Text(trade.symbol,
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(width: 8),
                Chip(
                  label: Text(
                    trade.outcome.name.toUpperCase(),
                    style: const TextStyle(fontSize: 9),
                  ),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                ),
              ],
            ),
            subtitle: Text(
              'Entry: ₹${trade.entryPrice.toStringAsFixed(1)} @ $entryTimeStr | '
              'Exit: ₹${trade.exitPrice?.toStringAsFixed(1) ?? "?"} @ $exitTimeStr | '
              'Qty: ${trade.quantity}',
              style: const TextStyle(fontSize: 11),
            ),
            trailing: Text(
              '${isWin ? "+" : ""}₹${trade.pnl.toStringAsFixed(0)}',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 16,
                color: isWin ? Colors.green : Colors.red,
              ),
            ),
          ),
        );
      },
    );
  }
}
