import 'dart:async';
import 'package:flutter/material.dart';
import '../models/holding_model.dart';
import '../services/dhan_service.dart';

class HoldingsScreen extends StatefulWidget {
  final DhanService dhanService;

  const HoldingsScreen({super.key, required this.dhanService});

  @override
  State<HoldingsScreen> createState() => _HoldingsScreenState();
}

class _HoldingsScreenState extends State<HoldingsScreen> {
  List<HoldingModel> _holdings = [];
  bool _isLoading = true;
  String? _error;
  Timer? _timer;
  DateTime? _lastUpdated;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() { _isLoading = true; _error = null; });
    try {
      final holdings = await widget.dhanService.fetchHoldings();
      if (!mounted) return;
      setState(() {
        _holdings = holdings;
        _isLoading = false;
        _lastUpdated = DateTime.now();
      });
      // Start live LTP refresh
      _refreshLTP();
      _timer = Timer.periodic(
          const Duration(seconds: 2), (_) => _refreshLTP());
    } on DhanAuthException catch (e) {
      if (!mounted) return;
      setState(() { _error = e.message; _isLoading = false; });
    } on DhanNetworkException catch (e) {
      if (!mounted) return;
      setState(() { _error = e.message; _isLoading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = e.toString(); _isLoading = false; });
    }
  }

  Future<void> _refreshLTP() async {
    if (_holdings.isEmpty) return;
    try {
      final ids = _holdings.map((h) => h.securityId).toList();
      final ltpMap = await widget.dhanService.fetchOhlcForIds(ids);
      if (!mounted) return;
      setState(() {
        for (final h in _holdings) {
          final ltp = ltpMap[h.securityId];
          if (ltp != null && ltp > 0) h.ltp = ltp;
        }
        _lastUpdated = DateTime.now();
      });
    } catch (_) { /* silently ignore */ }
  }

  // ── Portfolio totals ─────────────────────────────────────────────────
  double get _totalInvested =>
      _holdings.fold(0, (s, h) => s + h.invested);
  double get _totalCurrent =>
      _holdings.fold(0, (s, h) => s + h.currentValue);
  double get _totalPnl => _totalCurrent - _totalInvested;
  double get _totalPnlPct =>
      _totalInvested > 0 ? (_totalPnl / _totalInvested) * 100 : 0;
  bool get _isOverallProfit => _totalPnl >= 0;

  String _fmtTime(DateTime dt) {
    final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final m = dt.minute.toString().padLeft(2, '0');
    final s = dt.second.toString().padLeft(2, '0');
    return '$h:$m:$s ${dt.hour >= 12 ? 'PM' : 'AM'}';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final pnlColor = _isOverallProfit ? Colors.green : Colors.red;
    final arrow = _isOverallProfit ? '▲' : '▼';

    return Scaffold(
      body: Column(
        children: [
          // ── Gradient header ─────────────────────────────────────────
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
                        const Expanded(
                          child: Text('Holdings',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold)),
                        ),
                        if (_lastUpdated != null)
                          Text(_fmtTime(_lastUpdated!),
                              style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.7),
                                  fontSize: 11)),
                      ],
                    ),
                  ),

                  // Portfolio value
                  if (!_isLoading && _error == null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Current Value',
                              style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.7),
                                  fontSize: 12)),
                          const SizedBox(height: 4),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                '₹${_fmt(_totalCurrent)}',
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 30,
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
                                    color: pnlColor.withValues(alpha: 0.25),
                                    borderRadius: BorderRadius.circular(20),
                                    border: Border.all(
                                        color: _isOverallProfit
                                            ? Colors.green.shade300
                                            : Colors.red.shade300),
                                  ),
                                  child: Text(
                                    '$arrow ${_totalPnl.abs() >= 1000 ? '₹${_fmt(_totalPnl.abs())}' : '₹${_totalPnl.abs().toStringAsFixed(2)}'}  (${_totalPnlPct.toStringAsFixed(2)}%)',
                                    style: TextStyle(
                                        color: _isOverallProfit
                                            ? Colors.green.shade200
                                            : Colors.red.shade200,
                                        fontWeight: FontWeight.w600,
                                        fontSize: 12),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Invested  ₹${_fmt(_totalInvested)}',
                            style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.65),
                                fontSize: 12),
                          ),
                        ],
                      ),
                    )
                  else
                    const SizedBox(height: 16),
                ],
              ),
            ),
          ),

          // ── Body ─────────────────────────────────────────────────────
          Expanded(child: _buildBody(isDark)),
        ],
      ),
    );
  }

  Widget _buildBody(bool isDark) {
    if (_isLoading) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Loading holdings...', style: TextStyle(color: Colors.grey)),
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
              Icon(Icons.error_outline, size: 56, color: Colors.red.shade300),
              const SizedBox(height: 16),
              const Text('Could not load holdings',
                  style: TextStyle(
                      fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text(_error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.grey, fontSize: 13)),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                onPressed: _load,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    if (_holdings.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.pie_chart_outline,
                size: 64, color: Colors.grey.shade300),
            const SizedBox(height: 16),
            const Text('No holdings found',
                style: TextStyle(
                    fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Text('Your long-term portfolio will appear here.',
                style: TextStyle(color: Colors.grey, fontSize: 13)),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        itemCount: _holdings.length,
        itemBuilder: (context, index) =>
            _holdingCard(_holdings[index], isDark),
      ),
    );
  }

  Widget _holdingCard(HoldingModel h, bool isDark) {
    final pnlColor = h.isProfit ? Colors.green : Colors.red;
    final arrow = h.isProfit ? '▲' : '▼';

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
            color: isDark
                ? Colors.grey.shade800
                : Colors.grey.shade200),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Top row: symbol + exchange + LTP
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(h.tradingSymbol,
                              style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.bold)),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.blue.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(h.exchange,
                                style: const TextStyle(
                                    fontSize: 10,
                                    color: Colors.blue,
                                    fontWeight: FontWeight.w600)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text('${h.totalQty} shares  ×  ₹${h.avgCostPrice.toStringAsFixed(2)} avg',
                          style: TextStyle(
                              fontSize: 11, color: Colors.grey.shade500)),
                    ],
                  ),
                ),
                // LTP
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text('₹${h.ltp.toStringAsFixed(2)}',
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.bold)),
                    Text('LTP',
                        style: TextStyle(
                            fontSize: 10, color: Colors.grey.shade400)),
                  ],
                ),
              ],
            ),

            const SizedBox(height: 12),
            Divider(height: 1, color: Colors.grey.withValues(alpha: 0.15)),
            const SizedBox(height: 12),

            // Bottom row: invested | current | P&L
            Row(
              children: [
                _miniStat('Invested',
                    '₹${_fmt(h.invested)}', Colors.grey),
                _miniStat('Current',
                    '₹${_fmt(h.currentValue)}', Colors.blue),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        '$arrow ₹${h.pnl.abs() >= 1000 ? _fmt(h.pnl.abs()) : h.pnl.abs().toStringAsFixed(2)}',
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: pnlColor),
                      ),
                      Text(
                        '${h.pnlPercent.toStringAsFixed(2)}%',
                        style: TextStyle(fontSize: 11, color: pnlColor),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _miniStat(String label, String value, Color color) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(
                  fontSize: 10, color: Colors.grey.shade500)),
          Text(value,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: color)),
        ],
      ),
    );
  }

  /// Format large numbers: 1,45,000 → "1.45L", 10,000 → "10K"
  String _fmt(double val) {
    if (val >= 1e7) return '${(val / 1e7).toStringAsFixed(2)}Cr';
    if (val >= 1e5) return '${(val / 1e5).toStringAsFixed(2)}L';
    if (val >= 1e3) return '${(val / 1e3).toStringAsFixed(1)}K';
    return val.toStringAsFixed(2);
  }
}
