import 'dart:async';
import 'package:candlesticks/candlesticks.dart';
import 'package:flutter/material.dart';
import '../services/dhan_feed_service.dart';
import '../services/dhan_service.dart';

enum _Interval { m5, m15 }

extension _IntervalLabel on _Interval {
  String get label {
    switch (this) {
      case _Interval.m5:
        return '5 min';
      case _Interval.m15:
        return '15 min';
    }
  }

  String get apiValue {
    switch (this) {
      case _Interval.m5:
        return '5';
      case _Interval.m15:
        return '15';
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
  bool _isLoadingMore = false;
  String? _error;
  // Tracks the oldest date we've loaded so far
  late DateTime _oldestLoadedDate;

  // Candle hover / OHLC display
  Candle? _hoveredCandle;
  int _pkgScrollIndex = -10; // mirrors the package's internal scroll index
  int _pkgScrollDragStartIndex = -10;
  double _pkgScrollDragStartX = 0;
  static const _defaultCandleWidth = 6.0; // package default before any zoom

  // ── Live feed ────────────────────────────────────────────────────────────
  DhanFeedService? _feed;
  StreamSubscription<Map<int, FeedUpdate>>? _feedSub;

  // Live price state (updates in real-time from WebSocket)
  late double _liveLtp;
  late double _liveOpen;
  late double _liveHigh;
  late double _liveLow;

  double get _liveChange =>
      widget.prevClose > 0 ? _liveLtp - widget.prevClose : 0;
  double get _liveChangePercent =>
      widget.prevClose > 0 ? (_liveChange / widget.prevClose) * 100 : 0;
  bool get _liveIsPositive => _liveChange >= 0;

  @override
  void initState() {
    super.initState();
    _liveLtp = widget.ltp;
    _liveOpen = widget.open;
    _liveHigh = widget.high;
    _liveLow = widget.low;
    _oldestLoadedDate = DateTime.now();
    _loadChart();
    _startFeed();
  }

  void _startFeed() {
    _feed = DhanFeedService(
      clientId: widget.dhanService.clientId,
      accessToken: widget.dhanService.accessToken,
    );
    _feedSub = _feed!.dataStream.listen((data) {
      final u = data[widget.securityId];
      if (u == null || u.ltp <= 0) return;
      _onTick(u);
    });
    _feed!.connect([widget.securityId]);
  }

  void _onTick(FeedUpdate u) {
    final ltp = u.ltp;
    setState(() {
      _liveLtp = ltp;
      if (u.open > 0) _liveOpen = u.open;
      if (ltp > _liveHigh) _liveHigh = ltp;
      if (ltp < _liveLow || _liveLow == 0) _liveLow = ltp;
    });
    _updateCurrentCandle(ltp);
  }

  void _updateCurrentCandle(double ltp) {
    if (_candles.isEmpty) return;

    final ist = DateTime.now().toUtc().add(const Duration(hours: 5, minutes: 30));
    final intervalMins = _selectedInterval == _Interval.m5 ? 5 : 15;
    final latest = _candles[0];
    final candleEnd = latest.date.add(Duration(minutes: intervalMins));

    if (ist.isBefore(candleEnd)) {
      // Still inside the current candle — update H/L/C
      setState(() {
        _candles[0] = Candle(
          date: latest.date,
          open: latest.open,
          high: ltp > latest.high ? ltp : latest.high,
          low: ltp < latest.low ? ltp : latest.low,
          close: ltp,
          volume: latest.volume,
        );
      });
    } else {
      // New interval started — add a fresh forming candle
      final newDate = _alignToInterval(ist, intervalMins);
      setState(() {
        _candles.insert(
          0,
          Candle(
            date: newDate,
            open: ltp,
            high: ltp,
            low: ltp,
            close: ltp,
            volume: 0,
          ),
        );
      });
    }
  }

  DateTime _alignToInterval(DateTime dt, int mins) {
    final m = (dt.minute ~/ mins) * mins;
    return DateTime(dt.year, dt.month, dt.day, dt.hour, m);
  }

  @override
  void dispose() {
    _feedSub?.cancel();
    _feed?.dispose();
    super.dispose();
  }

  // Minimum candles needed to fill the screen (~6px each, ~330px usable)
  static const _minCandles = 60;

  Future<void> _loadChart() async {
    setState(() {
      _isLoading = true;
      _error = null;
      _candles = [];
      _oldestLoadedDate = DateTime.now();
      _pkgScrollIndex = -10;
      _pkgScrollDragStartIndex = -10;
      _hoveredCandle = null;
    });

    try {
      // Load today's candles
      var allCandles = await widget.dhanService.fetchIntraday(
        widget.securityId,
        _selectedInterval.apiValue,
      );

      // Auto-load previous days until chart is full
      DateTime dayToLoad = _oldestLoadedDate;
      int attempts = 0;
      while (allCandles.length < _minCandles && attempts < 10) {
        dayToLoad = _prevWeekday(dayToLoad);
        attempts++;
        try {
          final moreCandles = await widget.dhanService.fetchIntraday(
            widget.securityId,
            _selectedInterval.apiValue,
            date: dayToLoad,
          );
          if (moreCandles.isNotEmpty) {
            allCandles = [...allCandles, ...moreCandles];
          }
        } catch (_) {
          // Skip failed days
        }
      }
      _oldestLoadedDate = dayToLoad;

      if (!mounted) return;
      setState(() {
        _candles = allCandles;
        _isLoading = false;
      });
    } on DhanAuthException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _isLoading = false;
      });
    } on DhanNetworkException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Failed to load chart data';
        _isLoading = false;
      });
    }
  }

  /// Called by the candlestick widget when user scrolls to the left edge.
  Future<void> _loadMoreCandles() async {
    if (_isLoadingMore) return;
    setState(() => _isLoadingMore = true);

    try {
      // Try up to 7 days back to handle weekends AND market holidays
      DateTime dayToTry = _prevWeekday(_oldestLoadedDate);
      List<Candle> moreCandles = [];

      for (int attempt = 0; attempt < 7; attempt++) {
        moreCandles = await widget.dhanService.fetchIntraday(
          widget.securityId,
          _selectedInterval.apiValue,
          date: dayToTry,
        );

        if (moreCandles.isNotEmpty) break;

        // No data (holiday or no trading) — skip to the day before
        _oldestLoadedDate = dayToTry;
        dayToTry = _prevWeekday(dayToTry);
      }

      if (!mounted) return;
      setState(() {
        if (moreCandles.isNotEmpty) {
          _candles = [..._candles, ...moreCandles];
        }
        // Always advance past the days we tried
        _oldestLoadedDate = dayToTry;
      });
    } catch (_) {
      // Silently ignore
    } finally {
      if (mounted) setState(() => _isLoadingMore = false);
    }
  }

  /// Returns the previous weekday (skips Saturday and Sunday).
  /// Holidays are handled by trying multiple days in _loadMoreCandles.
  DateTime _prevWeekday(DateTime date) {
    var prev = date.subtract(const Duration(days: 1));
    while (prev.weekday == DateTime.saturday ||
        prev.weekday == DateTime.sunday) {
      prev = prev.subtract(const Duration(days: 1));
    }
    return prev;
  }

  // ── Candle hover tracking ────────────────────────────────────────────────

  void _onPointerDown(PointerDownEvent e, double chartWidth) {
    _pkgScrollDragStartX = e.localPosition.dx;
    _pkgScrollDragStartIndex = _pkgScrollIndex;
    _updateHoveredCandle(e.localPosition.dx, chartWidth);
  }

  void _onPointerMove(PointerMoveEvent e, double chartWidth) {
    // Mirror the package's scroll formula: index = lastIndex + dx ~/ candleWidth
    final dx = e.localPosition.dx - _pkgScrollDragStartX;
    _pkgScrollIndex = (_pkgScrollDragStartIndex + dx ~/ _defaultCandleWidth)
        .clamp(-10, _candles.length - 1);
    _updateHoveredCandle(e.localPosition.dx, chartWidth);
  }

  void _onPointerUp(PointerUpEvent e) {
    _pkgScrollDragStartIndex = _pkgScrollIndex; // mirrors package's onPanEnd
    if (mounted) setState(() => _hoveredCandle = null);
  }

  void _updateHoveredCandle(double x, double chartWidth) {
    const priceBarWidth = 60.0;
    final usableWidth = chartWidth - priceBarWidth;
    if (_candles.isEmpty || x < 0 || x >= usableWidth) {
      setState(() => _hoveredCandle = null);
      return;
    }
    final baseIdx = _pkgScrollIndex < 0 ? 0 : _pkgScrollIndex;
    final candlesFromRight = ((usableWidth - x) / _defaultCandleWidth).round();
    final idx = (baseIdx + candlesFromRight).clamp(0, _candles.length - 1);
    setState(() => _hoveredCandle = _candles[idx]);
  }

  String _fmtVol(double vol) {
    if (vol >= 1e6) return '${(vol / 1e6).toStringAsFixed(1)}M';
    if (vol >= 1e3) return '${(vol / 1e3).toStringAsFixed(0)}K';
    return vol.toStringAsFixed(0);
  }

  void _selectInterval(_Interval interval) {
    if (_selectedInterval == interval) return;
    setState(() => _selectedInterval = interval);
    _loadChart();
  }

  @override
  Widget build(BuildContext context) {
    final arrow = _liveIsPositive ? '▲' : '▼';
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
                          icon: const Icon(
                            Icons.arrow_back,
                            color: Colors.white,
                          ),
                          onPressed: () => Navigator.pop(context),
                        ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                widget.symbol,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              Text(
                                widget.name,
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.8),
                                  fontSize: 11,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.4),
                            ),
                          ),
                          child: const Text(
                            'NSE',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  // Price row — live via WebSocket
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          '₹${_liveLtp.toStringAsFixed(2)}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 32,
                            fontWeight: FontWeight.bold,
                            letterSpacing: -0.5,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: _liveIsPositive
                                  ? Colors.green.withValues(alpha: 0.25)
                                  : Colors.red.withValues(alpha: 0.25),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color: _liveIsPositive
                                    ? Colors.green.shade300
                                    : Colors.red.shade300,
                              ),
                            ),
                            child: Text(
                              '$arrow ${_liveChange.abs().toStringAsFixed(2)}  (${_liveChangePercent.toStringAsFixed(2)}%)',
                              style: TextStyle(
                                color: _liveIsPositive
                                    ? Colors.green.shade200
                                    : Colors.red.shade200,
                                fontWeight: FontWeight.w600,
                                fontSize: 13,
                              ),
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
              color: isDark ? Colors.grey.shade900 : Colors.grey.shade50,
              border: Border(
                bottom: BorderSide(color: Colors.grey.withValues(alpha: 0.15)),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _statItem('Open',  '₹${_liveOpen.toStringAsFixed(2)}',       Colors.blue),
                _vDivider(),
                _statItem('High',  '₹${_liveHigh.toStringAsFixed(2)}',       Colors.green),
                _vDivider(),
                _statItem('Low',   '₹${_liveLow.toStringAsFixed(2)}',        Colors.red),
                _vDivider(),
                _statItem('Prev',  '₹${widget.prevClose.toStringAsFixed(2)}', Colors.grey),
              ],
            ),
          ),

          // ── Interval selector ─────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
            child: Row(
              children: [
                const Text(
                  'Interval',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey,
                    fontWeight: FontWeight.w500,
                  ),
                ),
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
                            horizontal: 16,
                            vertical: 7,
                          ),
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
                              color: isSelected ? Colors.white : Colors.grey,
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
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
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
                  if (_isLoadingMore) ...[
                    const SizedBox(
                      width: 11,
                      height: 11,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Loading older data...',
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.grey.shade400,
                      ),
                    ),
                  ] else ...[
                    Icon(Icons.swipe, size: 13, color: Colors.grey.shade400),
                    const SizedBox(width: 4),
                    Text(
                      'Touch candle for OHLC  •  Scroll left for older',
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.grey.shade400,
                      ),
                    ),
                  ],
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
        Text(label, style: const TextStyle(fontSize: 10, color: Colors.grey)),
        const SizedBox(height: 3),
        Text(
          value,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
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
              width: 40,
              height: 40,
              child: CircularProgressIndicator(strokeWidth: 3),
            ),
            const SizedBox(height: 16),
            Text(
              'Loading ${_selectedInterval.label} candles...',
              style: const TextStyle(color: Colors.grey),
            ),
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
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.wifi_off_rounded,
                  size: 36,
                  color: Colors.red,
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Could not load chart',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.grey, fontSize: 13),
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 10,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
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
            Icon(
              Icons.candlestick_chart_outlined,
              size: 64,
              color: Colors.grey.shade300,
            ),
            const SizedBox(height: 16),
            const Text(
              'No data for today',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
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

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF121212) : Colors.white;

    return LayoutBuilder(
      builder: (context, constraints) {
        // The package hardcodes "-XXXXK" as the volume axis label.
        // We cover it and render our own "VOL" label.
        // Formula: toolbar(30) + (height - 50) * 0.75 ≈ height * 0.75 - 7.5
        final volumeLabelTop = constraints.maxHeight * 0.75 - 8;

        return Listener(
          onPointerDown: (e) => _onPointerDown(e, constraints.maxWidth),
          onPointerMove: (e) => _onPointerMove(e, constraints.maxWidth),
          onPointerUp: _onPointerUp,
          onPointerCancel: (_) => setState(() => _hoveredCandle = null),
          child: Stack(
            children: [
              Candlesticks(
                candles: _candles,
                onLoadMoreCandles: _loadMoreCandles,
                actions: [
                  ToolBarAction(
                    width: 38,
                    onPressed: _loadChart,
                    child: const Tooltip(
                      message: 'Jump to latest',
                      child: Icon(Icons.skip_next, size: 20),
                    ),
                  ),
                ],
              ),
              // Covers package's hardcoded "-XXXXK" volume axis label.
              // Shows hovered candle's volume, otherwise "VOL".
              Positioned(
                top: volumeLabelTop,
                right: 0,
                width: 60,
                height: 22,
                child: Container(
                  color: bgColor,
                  alignment: Alignment.centerLeft,
                  padding: const EdgeInsets.only(left: 4),
                  child: Text(
                    _hoveredCandle != null
                        ? _fmtVol(_hoveredCandle!.volume)
                        : 'VOL',
                    style: TextStyle(
                      fontSize: 9,
                      fontWeight: _hoveredCandle != null
                          ? FontWeight.w600
                          : FontWeight.normal,
                      color: _hoveredCandle != null
                          ? Colors.blue.shade300
                          : Colors.grey.shade400,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

}
