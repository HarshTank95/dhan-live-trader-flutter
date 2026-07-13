import 'base_strategy.dart';
import 'dominance_breakout_strategy.dart';
import 'hammer_dominance_strategy.dart';
import 'hammer_lab_strategy.dart';
import 'orb_strategy.dart';

/// Registry of all available strategy types.
/// To add a new strategy: create the class, then register it here.
class StrategyRegistry {
  static final Map<String, BaseStrategy Function()> _factories = {};

  static void init() {
    register('dominance_breakout', () => DominanceBreakoutStrategy());
    register('hammer_dominance_s1', () => HammerDominanceStrategy());
    register('hammer_lab', () => HammerLabStrategy());
    register('orb', () => OrbStrategy());
  }

  static void register(String type, BaseStrategy Function() factory) {
    _factories[type] = factory;
  }

  static BaseStrategy? create(String type) => _factories[type]?.call();

  static List<BaseStrategy> get allTypes =>
      _factories.values.map((f) => f()).toList();
}
