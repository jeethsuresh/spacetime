import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';

const double _defaultDepth = .075;

/// A bounded visual pose. Reciprocal scales preserve the art's painted area.
class ElasticPose {
  const ElasticPose(
    this.energy, {
    this.depth = _defaultDepth,
    this.tilt = .018,
    this.travel = 1.5,
  });
  final double energy, depth, tilt, travel;

  Widget deform(
    Widget child, {
    double gain = 1,
    bool position = true,
    Key? key,
  }) {
    final e = energy.clamp(-.85, 1.0);
    final y = (1 - depth * e * gain).clamp(.82, 1.16);
    final angle = position ? tilt * e * gain : 0.0;
    final c = math.cos(angle), s = math.sin(angle);
    final matrix =
        Matrix4.identity()
          ..setEntry(0, 0, c / y)
          ..setEntry(0, 1, -s * y)
          ..setEntry(1, 0, s / y)
          ..setEntry(1, 1, c * y)
          ..setEntry(1, 3, position ? travel * e * gain : 0.0);
    return Transform(
      key: key,
      alignment: Alignment.center,
      transformHitTests: false,
      transform: matrix,
      child: child,
    );
  }
}

/// Marks the art layer inside a fixed control.
class ElasticArt extends StatelessWidget {
  const ElasticArt({super.key, required this.child, this.gain = 1});
  final Widget child;
  final double gain;
  @override
  Widget build(BuildContext context) =>
      (_ElasticScope.of(context) ?? const ElasticPose(0)).deform(
        child,
        gain: gain,
      );
}

class _ElasticScope extends InheritedWidget {
  const _ElasticScope({required this.pose, required super.child});
  final ElasticPose pose;
  static ElasticPose? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_ElasticScope>()?.pose;
  @override
  bool updateShouldNotify(_ElasticScope old) => old.pose.energy != pose.energy;
}

/// Observes input; the existing Material control remains the only action owner.
class ElasticInteraction extends StatefulWidget {
  const ElasticInteraction({
    super.key,
    this.child,
    this.builder,
    this.enabled = true,
    this.depth = _defaultDepth,
    this.tilt = .018,
    this.travel = 1.5,
  }) : assert((child == null) != (builder == null));
  final Widget? child;
  final Widget Function(BuildContext, ElasticPose)? builder;
  final bool enabled;
  final double depth, tilt, travel;
  @override
  State<ElasticInteraction> createState() => _ElasticInteractionState();
}

class _ElasticInteractionState extends State<ElasticInteraction>
    with SingleTickerProviderStateMixin {
  late final phase = AnimationController.unbounded(vsync: this, value: 0);
  int generation = 0;
  int? pointer;
  Offset? origin;
  LogicalKeyboardKey? activationKey;
  bool reduced = false;
  bool get held => pointer != null || activationKey != null;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(keyEvent);
    FocusManager.instance.addListener(focusChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    reduced = MediaQuery.disableAnimationsOf(context);
    if (reduced) normalise();
  }

  @override
  void didUpdateWidget(covariant ElasticInteraction oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled && held) finish(false);
  }

  void normalise() {
    generation++;
    pointer = null;
    origin = null;
    activationKey = null;
    phase.value = 0;
  }

  bool ownsFocus() {
    final focused = FocusManager.instance.primaryFocus?.context;
    return focused != null &&
        focused.mounted &&
        focused.findAncestorStateOfType<_ElasticInteractionState>() == this;
  }

  void focusChanged() {
    if (activationKey != null && !ownsFocus()) finish(false);
  }

  bool keyEvent(KeyEvent event) {
    const keys = [
      LogicalKeyboardKey.space,
      LogicalKeyboardKey.enter,
      LogicalKeyboardKey.numpadEnter,
    ];
    if (event is KeyUpEvent && event.logicalKey == activationKey) {
      finish(widget.enabled && ownsFocus());
    } else if (event is KeyDownEvent &&
        keys.contains(event.logicalKey) &&
        widget.enabled &&
        !held &&
        ownsFocus()) {
      activationKey = event.logicalKey;
      unawaited(windUp());
    }
    return false;
  }

  bool inside(Offset global) {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return false;
    return (Offset.zero & box.size).contains(box.globalToLocal(global));
  }

  void down(PointerDownEvent event) {
    if (!widget.enabled || held || event.buttons != kPrimaryButton) return;
    pointer = event.pointer;
    origin = event.position;
    unawaited(windUp());
  }

  void move(PointerMoveEvent event) {
    if (event.pointer == pointer &&
        (!inside(event.position) ||
            (event.position - origin!).distance > kTouchSlop)) {
      finish(false);
    }
  }

  Future<void> windUp() async {
    final token = ++generation;
    if (reduced) {
      phase.value = 0;
      return;
    }
    try {
      await phase
          .animateTo(
            .70,
            duration: const Duration(milliseconds: 70),
            curve: Curves.easeOutCubic,
          )
          .orCancel;
      if (mounted && token == generation && held) {
        await phase
            .animateTo(
              1,
              duration: const Duration(milliseconds: 150),
              curve: Curves.easeOutCubic,
            )
            .orCancel;
      }
    } on TickerCanceled {
      /* Retargeted or disposed. */
    }
  }

  void finish(bool accepted) {
    pointer = null;
    origin = null;
    activationKey = null;
    unawaited(relax(accepted));
  }

  Future<void> relax(bool accepted) async {
    final token = ++generation;
    if (reduced) {
      phase.value = 0;
      return;
    }
    try {
      if (!accepted) {
        await phase
            .animateTo(
              0,
              duration: const Duration(milliseconds: 100),
              curve: Curves.easeOutCubic,
            )
            .orCancel;
      } else {
        await phase
            .animateTo(
              -.62,
              duration: const Duration(milliseconds: 110),
              curve: Curves.easeOutCubic,
            )
            .orCancel;
        if (!mounted || token != generation) return;
        await phase
            .animateWith(
              SpringSimulation(
                const SpringDescription(mass: 1, stiffness: 430, damping: 25),
                phase.value,
                0,
                0,
              ),
            )
            .orCancel;
      }
      if (mounted && token == generation) phase.value = 0;
    } on TickerCanceled {
      /* New input owns the current pose. */
    }
  }

  @override
  void dispose() {
    generation++;
    HardwareKeyboard.instance.removeHandler(keyEvent);
    FocusManager.instance.removeListener(focusChanged);
    phase.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: phase,
    child: widget.child,
    builder: (context, child) {
      final pose = ElasticPose(
        reduced ? 0 : phase.value,
        depth: widget.depth,
        tilt: widget.tilt,
        travel: widget.travel,
      );
      return Listener(
        onPointerDown: down,
        onPointerMove: move,
        onPointerUp: (event) {
          if (event.pointer == pointer) {
            finish(widget.enabled && inside(event.position));
          }
        },
        onPointerCancel: (event) {
          if (event.pointer == pointer) finish(false);
        },
        child: _ElasticScope(
          pose: pose,
          child: widget.builder?.call(context, pose) ?? pose.deform(child!),
        ),
      );
    },
  );
}

/// A separate, once-per-confirmed-event art pulse. Mount/restore never replays it.
class ElasticPulse extends StatefulWidget {
  const ElasticPulse({
    super.key,
    required this.signal,
    required this.child,
    this.amount = .12,
  });
  final int signal;
  final Widget child;
  final double amount;
  @override
  State<ElasticPulse> createState() => _ElasticPulseState();
}

class _ElasticPulseState extends State<ElasticPulse>
    with SingleTickerProviderStateMixin {
  late final pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 360),
    value: 1,
  );
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) pulse.value = 1;
  }

  @override
  void didUpdateWidget(covariant ElasticPulse oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.signal == 0 || MediaQuery.disableAnimationsOf(context)) {
      pulse.value = 1;
    } else if (widget.signal != oldWidget.signal) {
      pulse.forward(from: 0);
    }
  }

  @override
  void dispose() {
    pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: pulse,
    child: widget.child,
    builder: (context, child) {
      final t = pulse.value;
      final energy =
          t == 1 ? 0.0 : -math.sin(2 * math.pi * t) * math.exp(-4 * t);
      return ElasticPose(
        energy,
        depth: widget.amount,
        tilt: 0,
        travel: 0,
      ).deform(child!);
    },
  );
}
