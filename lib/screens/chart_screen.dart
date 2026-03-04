import 'package:candlesticks/candlesticks.dart';
import 'package:flutter/material.dart';
import '../services/dhan_service.dart';

enum _Interval { m5, m15 }

extension _IntervalLabel on _Interval {
  String get label {
    switch (this) {
      case _Interval.m5:  return '5 min';
      case _Interval.m15: return '15 min';
    }
  }

  String get apiValue {
    switch (this) {
      case _Interval.m5:  return '5';
      case _Interval.m15: return '15';
    }
  }
}

class ChartScreen extends StatefulWidget {
  final int securityId;
  final String symbol;
  final String name;
  final double ltp;
  final double change;
  final double changePercent;
  final double open;
  final double high;
  final double low;
  final double prevClose;
  final bool isPositive;
  final DhanService dhanService;

  const ChartScreen({
    super.key,
    required this.securityId,
    required this.symbol,
    required this.name,
    required this.ltp,
    required this.change,
    required this.changePercent,
    required this.open,
    required this.high,
    required this.low,
    required this.prevClose,
    required this.isPositive,
    required this.dhanService,
  });

  @override
  State<ChartScreen> createState() => _ChartScreenState();
}

class _ChartScreenState extends State<ChartScreen> {
  _Interval _selectedInterval = _Interval.m15;
  List<Candle> _candles = [];
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadChart();
  }

  Future<void> _loadChart() async {
    setState(() {
      _isLoading = true;
      _error = null;
      _candles = [];
    });

    try {
      final candles = await widget.dhanService.fetchIntraday(
        widget.securityId,
        _selectedInterval.apiValue,
      );
      if (!mounted) return;
      setState(() {
        _candles = candles;
        _isLoading = false;
      });
    } on DhanAuthException catch (e) {
      if (!mounted) return;
      setState(() { _error = e.message; _isLoading = false; });
    } on DhanNetworkException catch (e) {
      if (!mounted) return;
      setState(() { _error = e.message; _isLoading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = 'Failed to load chart data'; _isLoading = false; });
    }
  }

  void _selectInterval(_Interval interval) {
    if (_selectedInterval == interval) return;
    setState(() => _selectedInterval = interval);
    _loadChart();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.isPositive ? Colors.green : Colors.red;
    final arrow = widget.isPositive ? '▲' : '▼';
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      body: Column(
        children: [
          // ── Gradient header ──────────────────────────────────────────
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFF1565C0), Color(0xFF42A5F5)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            child: SafeArea(
              bottom: false,
              child: Column(
                children: [
                  // App bar row
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 4, 16, 0),
                    child: Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.arrow_back,
                              color: Colors.white),
                          onPressed: () => Navigator.pop(context),
                        ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(widget.symbol,
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 18,
                                      fontWeight: FontWeight.bold)),
                              Text(widget.name,
                                  style: TextStyle(
                                      color: Colors.white.withValues(alpha: 0.8),
                                      fontSize: 11),
                                  overflow: TextOverflow.ellipsis),
                            ],
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                                color: Colors.white.withValues(alpha: 0.4)),
                          ),
                          child: const Text('NSE',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600)),
                        ),
                      ],
                    ),
                  ),

                  // Price row
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          '₹${widget.ltp.toStringAsFixed(2)}',
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 32,
                              fontWeight: FontWeight.bold,
                              letterSpacing: -0.5),
                        ),
                        const SizedBox(width: 12),
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: widget.isPositive
                                  ? Colors.green.withValues(alpha: 0.25)
                                  : Colors.red.withValues(alpha: 0.25),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color: widget.isPositive
                                    ? Colors.green.shade300
                                    : Colors.red.shade300,
                              ),
                            ),
                            child: Text(
                              '$arrow ${widget.change.abs().toStringAsFixed(2)}  (${widget.changePercent.toStringAsFixed(2)}%)',
                              style: TextStyle(
                                  color: widget.isPositive
                                      ? Colors.green.shade200
                                      : Colors.red.shade200,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ── OHLC stats row ───────────────────────────────────────────
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: isDark
                  ? Colors.grey.shade900
                  : Colors.grey.shade50,
              border: Border(
                bottom: BorderSide(
                    color: Colors.grey.withValues(alpha: 0.15)),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _statItem('Open',
                    '₹${widget.open.toStringAsFixed(2)}', Colors.blue),
                _vDivider(),
                _statItem('High',
                    '₹${widget.high.toStringAsFixed(2)}', Colors.green),
                _vDivider(),
                _statItem('Low',
                    '₹${widget.low.toStringAsFixed(2)}', Colors.red),
                _vDivider(),
                _statItem('Prev Close',
                    '₹${widget.prevClose.toStringAsFixed(2)}', Colors.grey),
              ],
            ),
          ),

          // ── Interval selector ────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
            child: Row(
              children: [
                const Text('Interval',
                    style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey,
                        fontWeight: FontWeight.w500)),
                const SizedBox(width: 12),
                Container(
                  decoration: BoxDecoration(
                    color: isDark
                        ? Colors.grey.shade800
                        : Colors.grey.shade200,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: _Interval.values.map((interval) {
                      final isSelected = _selectedInterval == interval;
                      return GestureDetector(
                        onTap: () => _selectInterval(interval),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 7),
                          decoration: BoxDecoration(
                            color: isSelected
                                ? Colors.blue
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            interval.label,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: isSelected
                                  ? Colors.white
                                  : Colors.grey,
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),
                const Spacer(),
                if (!_isLoading && _candles.isNotEmpty)
                  Text(
                    '${_candles.length} candles',
                    style: const TextStyle(
                        fontSize: 11, color: Colors.grey),
                  ),
              ],
            ),
          ),

          // ── Chart ────────────────────────────────────────────────────
          Expanded(child: _buildChartArea()),

          // ── Bottom hint ──────────────────────────────────────────────
          if (!_isLoading && _candles.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 8),
              color: isDark ? Colors.grey.shade900 : Colors.grey.shade50,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.swipe, size: 13, color: Colors.grey.shade400),
                  const SizedBox(width: 4),
                  Text('Scroll to navigate  •  Pinch to zoom',
                      style: TextStyle(
                          fontSize: 11, color: Colors.grey.shade400)),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _statItem(String label, String value, Color color) {
    return Column(
      children: [
        Text(label,
            style: const TextStyle(fontSize: 10, color: Colors.grey)),
        const SizedBox(height: 3),
        Text(value,
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: color)),
      ],
    );
  }

  Widget _vDivider() => Container(
        height: 28,
        width: 1,
        color: Colors.grey.withValues(alpha: 0.2),
      );

  Widget _buildChartArea() {
    if (_isLoading) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(
              width: 40, height: 40,
              child: CircularProgressIndicator(strokeWidth: 3),
            ),
            const SizedBox(height: 16),
            Text('Loading ${_selectedInterval.label} candles...',
                style: const TextStyle(color: Colors.grey)),
          ],
        ),
      );
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 72, height: 72,
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.wifi_off_rounded,
                    size: 36, color: Colors.red),
              ),
              const SizedBox(height: 16),
              const Text('Could not load chart',
                  style: TextStyle(
                      fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text(_error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: Colors.grey, fontSize: 13)),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 24, vertical: 10),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                onPressed: _loadChart,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    if (_candles.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.candlestick_chart_outlined,
                size: 64, color: Colors.grey.shade300),
            const SizedBox(height: 16),
            const Text('No data for today',
                style: TextStyle(
                    fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Text(
              'Intraday data is only available\non market trading days',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey, fontSize: 13),
            ),
          ],
        ),
      );
    }

    return Candlesticks(candles: _candles);
  }
}
