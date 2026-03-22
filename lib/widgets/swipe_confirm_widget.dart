import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class SwipeConfirmWidget extends StatefulWidget {
  final String text;
  final Color color;
  final VoidCallback onConfirmed;
  final double height;

  const SwipeConfirmWidget({
    super.key,
    required this.text,
    required this.color,
    required this.onConfirmed,
    this.height = 56,
  });

  @override
  State<SwipeConfirmWidget> createState() => _SwipeConfirmWidgetState();
}

class _SwipeConfirmWidgetState extends State<SwipeConfirmWidget>
    with TickerProviderStateMixin {
  double _dragOffset = 0;
  double _maxDrag = 0;
  bool _confirmed = false;
  late AnimationController _springController;
  late Animation<double> _springAnimation;
  late AnimationController _pulseController;
  late AnimationController _shimmerController;

  static const double _thumbWidth = 58;
  static const double _padding = 4;
  static const double _threshold = 0.75;

  double _dragStartOffset = 0;

  @override
  void initState() {
    super.initState();
    _springController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _springAnimation = CurvedAnimation(
      parent: _springController,
      curve: Curves.elasticOut,
    );
    _springController.addListener(() {
      setState(() {
        _dragOffset = _springAnimation.value * _dragStartOffset;
      });
    });

    // Pulse glow on thumb
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);

    // Shimmer on text
    _shimmerController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat();
  }

  @override
  void dispose() {
    _springController.dispose();
    _pulseController.dispose();
    _shimmerController.dispose();
    super.dispose();
  }

  void _onDragUpdate(DragUpdateDetails details) {
    if (_confirmed) return;
    setState(() {
      _dragOffset = (_dragOffset + details.delta.dx).clamp(0.0, _maxDrag);
    });
  }

  void _onDragEnd(DragEndDetails details) {
    if (_confirmed) return;

    if (_dragOffset >= _maxDrag * _threshold) {
      setState(() {
        _confirmed = true;
        _dragOffset = _maxDrag;
      });
      HapticFeedback.heavyImpact();
      _pulseController.stop();
      _shimmerController.stop();
      Future.delayed(const Duration(milliseconds: 200), widget.onConfirmed);
    } else {
      _dragStartOffset = _dragOffset;
      _springController.reset();
      _springController.reverse(from: 1.0);
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _maxDrag = constraints.maxWidth - _thumbWidth - (_padding * 2);
        final progress = _maxDrag > 0 ? (_dragOffset / _maxDrag) : 0.0;
        final thumbHeight = widget.height - (_padding * 2);
        final radius = widget.height / 2;

        return Container(
          height: widget.height,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius),
            gradient: LinearGradient(
              colors: [
                widget.color.withValues(alpha: 0.9),
                widget.color,
                widget.color.withValues(alpha: 0.9),
              ],
              stops: const [0.0, 0.5, 1.0],
            ),
            boxShadow: [
              BoxShadow(
                color: widget.color.withValues(alpha: 0.35),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
              BoxShadow(
                color: widget.color.withValues(alpha: 0.15),
                blurRadius: 4,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Stack(
            children: [
              // Shimmer sweep across the track
              if (!_confirmed)
                AnimatedBuilder(
                  animation: _shimmerController,
                  builder: (context, _) {
                    final sweep = _shimmerController.value;
                    return ClipRRect(
                      borderRadius: BorderRadius.circular(radius),
                      child: ShaderMask(
                        shaderCallback: (bounds) {
                          return LinearGradient(
                            begin: Alignment(-1.0 + 3.0 * sweep, 0),
                            end: Alignment(-0.5 + 3.0 * sweep, 0),
                            colors: [
                              Colors.transparent,
                              Colors.white.withValues(alpha: 0.07),
                              Colors.transparent,
                            ],
                          ).createShader(bounds);
                        },
                        blendMode: BlendMode.srcATop,
                        child: Container(
                          height: widget.height,
                          color: Colors.white.withValues(alpha: 0.03),
                        ),
                      ),
                    );
                  },
                ),

              // Text label
              Center(
                child: Opacity(
                  opacity: (1.0 - progress * 2.0).clamp(0.0, 1.0),
                  child: Padding(
                    padding: EdgeInsets.only(left: _thumbWidth * 0.6),
                    child: Text(
                      widget.text,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.95),
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                ),
              ),

              // Draggable thumb
              Positioned(
                left: _dragOffset + _padding,
                top: _padding,
                child: GestureDetector(
                  onHorizontalDragUpdate: _onDragUpdate,
                  onHorizontalDragEnd: _onDragEnd,
                  child: AnimatedBuilder(
                    animation: _pulseController,
                    builder: (context, child) {
                      final pulse = _confirmed ? 0.0 : _pulseController.value;
                      return Container(
                        width: _thumbWidth,
                        height: thumbHeight,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(thumbHeight / 2),
                          color: Colors.white,
                          boxShadow: [
                            BoxShadow(
                              color: Colors.white.withValues(
                                  alpha: 0.2 + pulse * 0.15),
                              blurRadius: 8 + pulse * 6,
                              spreadRadius: pulse * 2,
                            ),
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.1),
                              blurRadius: 4,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: _confirmed
                              ? [
                                  Icon(Icons.check_rounded,
                                      color: widget.color, size: 22)
                                ]
                              : [
                                  Icon(Icons.chevron_right_rounded,
                                      color: widget.color.withValues(alpha: 0.5),
                                      size: 20),
                                  Icon(Icons.chevron_right_rounded,
                                      color: widget.color.withValues(alpha: 0.8),
                                      size: 20),
                                ],
                        ),
                      );
                    },
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
