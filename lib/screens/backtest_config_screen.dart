import 'package:flutter/material.dart';
import '../services/rate_limiter.dart';
import '../services/scrip_service.dart';
import 'backtest_progress_screen.dart';

class BacktestConfigScreen extends StatefulWidget {
  final String accessToken;
  final String clientId;

  const BacktestConfigScreen({
    super.key,
    required this.accessToken,
    required this.clientId,
  });

  @override
  State<BacktestConfigScreen> createState() => _BacktestConfigScreenState();
}

class _BacktestConfigScreenState extends State<BacktestConfigScreen> {
  // Date range
  DateTime _fromDate = DateTime.now().subtract(const Duration(days: 30));
  DateTime _toDate = DateTime.now().subtract(const Duration(days: 1));
  String _preset = '30d';

  // Stock universe
  String _universe = 'Nifty 500';
  int _universeSize = 500;

  // Strategy params (using defaults)
  final Map<String, dynamic> _params = {
    'historicalDays': 10,
    'candleInterval': '5',
    'scanStartHour': 9,
    'scanStartMin': 30,
    'scanEndHour': 10,
    'scanEndMin': 0,
    'scanIntervalMinutes': 5,
    'minBodyPercent': 70.0,
    'maxBodyPercent': 85.0,
    'minWickPercent': 5.0,
    'minCandleSizeMultiplier': 1.0,
    'maxCandleSizeMultiplier': 2.5,
    'minVolumeMultiplier': 2.0,
    'minAbsoluteVolume': 5000,
    'maxMovementMultiplier': 2.0,
    'maxGapUpPercent': 2.5,
    'maxGapDownPercent': 1.0,
    'fixedStopLoss': 500.0,
    'fixedTarget': 2000.0,
    'maxTradesPerDay': 2,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final stats = RateLimiter.instance.stats;
    final estimatedCalls = _estimateApiCalls();
    final canRun = estimatedCalls <= stats.dataCallsRemaining;

    return Scaffold(
      appBar: AppBar(title: const Text('Backtest Setup')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Date Range Section
          _sectionHeader('Date Range', Icons.calendar_today),
          const SizedBox(height: 8),
          _buildPresetChips(),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: _buildDateButton('From', _fromDate, (d) {
                setState(() {
                  _fromDate = d;
                  _preset = 'custom';
                });
              })),
              const SizedBox(width: 12),
              Expanded(child: _buildDateButton('To', _toDate, (d) {
                setState(() {
                  _toDate = d;
                  _preset = 'custom';
                });
              })),
            ],
          ),
          Text(
            '${_tradingDaysEstimate()} trading days',
            style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey),
          ),

          const SizedBox(height: 24),

          // Stock Universe Section
          _sectionHeader('Stock Universe', Icons.groups),
          const SizedBox(height: 8),
          _buildUniverseSelector(),

          const SizedBox(height: 24),

          // Position Sizing Section
          _sectionHeader('Position Sizing', Icons.attach_money),
          const SizedBox(height: 8),
          _buildParamRow('Stop Loss (INR)', 'fixedStopLoss', 100, 5000, 'INR'),
          _buildParamRow('Target (INR)', 'fixedTarget', 100, 10000, 'INR'),
          _buildParamRow('Max Trades/Day', 'maxTradesPerDay', 1, 10, ''),

          const SizedBox(height: 24),

          // API Usage Estimate
          _sectionHeader('API Usage Estimate', Icons.data_usage),
          const SizedBox(height: 8),
          _buildApiEstimate(stats, estimatedCalls, canRun),

          const SizedBox(height: 32),

          // Start Button
          SizedBox(
            height: 52,
            child: ElevatedButton.icon(
              onPressed: canRun ? _startBacktest : null,
              icon: const Icon(Icons.play_arrow),
              label: const Text('Start Backtest', style: TextStyle(fontSize: 16)),
              style: ElevatedButton.styleFrom(
                backgroundColor: canRun ? Colors.blue : Colors.grey,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(String title, IconData icon) {
    return Row(
      children: [
        Icon(icon, size: 20, color: Colors.blue),
        const SizedBox(width: 8),
        Text(title,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
      ],
    );
  }

  Widget _buildPresetChips() {
    final presets = {
      '7d': ('7 Days', 7),
      '30d': ('30 Days', 30),
      '90d': ('90 Days', 90),
      '180d': ('6 Months', 180),
      '365d': ('1 Year', 365),
    };

    return Wrap(
      spacing: 8,
      children: presets.entries.map((e) {
        final selected = _preset == e.key;
        return ChoiceChip(
          label: Text(e.value.$1),
          selected: selected,
          onSelected: (_) {
            setState(() {
              _preset = e.key;
              _toDate = DateTime.now().subtract(const Duration(days: 1));
              _fromDate = _toDate.subtract(Duration(days: e.value.$2));
            });
          },
        );
      }).toList(),
    );
  }

  Widget _buildDateButton(
      String label, DateTime date, void Function(DateTime) onPicked) {
    return OutlinedButton(
      onPressed: () async {
        final picked = await showDatePicker(
          context: context,
          initialDate: date,
          firstDate: DateTime.now().subtract(const Duration(days: 365 * 5)),
          lastDate: DateTime.now(),
        );
        if (picked != null) onPicked(picked);
      },
      child: Column(
        children: [
          Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
          Text(
            '${date.day}/${date.month}/${date.year}',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }

  Widget _buildUniverseSelector() {
    final options = [
      ('Nifty 50', 50),
      ('Nifty 200', 200),
      ('Nifty 500', 500),
    ];

    return SegmentedButton<String>(
      segments: options
          .map((o) => ButtonSegment(
                value: o.$1,
                label: Text(o.$1),
              ))
          .toList(),
      selected: {_universe},
      onSelectionChanged: (val) {
        final selected = options.firstWhere((o) => o.$1 == val.first);
        setState(() {
          _universe = selected.$1;
          _universeSize = selected.$2;
        });
      },
    );
  }

  Widget _buildParamRow(
      String label, String key, double min, double max, String unit) {
    final value = (_params[key] as num).toDouble();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(flex: 3, child: Text(label)),
          Expanded(
            flex: 4,
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              divisions: ((max - min) / (key == 'maxTradesPerDay' ? 1 : 100))
                  .round()
                  .clamp(1, 100),
              label: key == 'maxTradesPerDay'
                  ? value.toInt().toString()
                  : value.toStringAsFixed(0),
              onChanged: (v) {
                setState(() {
                  _params[key] = key == 'maxTradesPerDay' ? v.toInt() : v;
                });
              },
            ),
          ),
          SizedBox(
            width: 60,
            child: Text(
              key == 'maxTradesPerDay'
                  ? value.toInt().toString()
                  : '${value.toStringAsFixed(0)} $unit'.trim(),
              textAlign: TextAlign.right,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildApiEstimate(
      RateLimiterStats stats, int estimatedCalls, bool canRun) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            _statRow('Stocks', '$_universeSize'),
            _statRow('Trading days (est.)', '~${_tradingDaysEstimate()}'),
            _statRow('API calls needed', '~$estimatedCalls'),
            _statRow('Est. download time', _estimateTime(estimatedCalls)),
            const Divider(),
            _statRow('API calls used today', '${stats.dataCallsToday}'),
            _statRow('API calls remaining', '${stats.dataCallsRemaining}'),
            _statRow(
              'Usage',
              '${stats.dataUsagePercent.toStringAsFixed(1)}%',
            ),
            if (!canRun)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'Not enough API quota remaining. Try a smaller universe or wait until tomorrow.',
                  style: TextStyle(color: Colors.red, fontSize: 12),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _statRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Colors.grey)),
          Text(value, style: const TextStyle(fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  int _tradingDaysEstimate() {
    final days = _toDate.difference(_fromDate).inDays;
    return (days * 5 / 7).round(); // rough weekday estimate
  }

  int _estimateApiCalls() {
    // 1 API call per stock for up to 90 days. Beyond 90 days, multiply.
    final totalDays = _toDate.difference(_fromDate).inDays;
    final historicalBuffer =
        ((_params['historicalDays'] as num?)?.toInt() ?? 10) + 20;
    final totalRange = totalDays + historicalBuffer;
    final windowCount = (totalRange / 90).ceil();
    return _universeSize * windowCount;
  }

  String _estimateTime(int calls) {
    final seconds = (calls / 5).ceil(); // 5 req/sec
    if (seconds < 60) return '~${seconds}s';
    final minutes = seconds ~/ 60;
    final remainSec = seconds % 60;
    return '~${minutes}m ${remainSec}s';
  }

  void _startBacktest() {
    // Get security IDs from ScripService
    final scripService = ScripService();
    final securityIds = scripService.getSecurityIdsForUniverse(_universe);

    if (securityIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No stocks found. Load scrip master first.')),
      );
      return;
    }

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => BacktestProgressScreen(
          accessToken: widget.accessToken,
          clientId: widget.clientId,
          fromDate: _fromDate,
          toDate: _toDate,
          stockUniverseLabel: _universe,
          securityIds: securityIds,
          params: Map.from(_params),
        ),
      ),
    );
  }
}
