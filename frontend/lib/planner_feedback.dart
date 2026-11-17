import 'package:flutter/material.dart';

/// A local save/completion accent, never a source of calendar or sync state.
class PlannerEntryFeedback extends StatefulWidget {
  const PlannerEntryFeedback({
    super.key,
    required this.signal,
    required this.color,
    required this.child,
  });
  final int signal;
  final Color color;
  final Widget child;
  @override
  State<PlannerEntryFeedback> createState() => _PlannerEntryFeedbackState();
}

class _PlannerEntryFeedbackState extends State<PlannerEntryFeedback>
    with SingleTickerProviderStateMixin {
  late final controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );
  bool reduced = false;
  @override
  void initState() {
    super.initState();
    if (widget.signal > 0) controller.value = 1;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    reduced = MediaQuery.disableAnimationsOf(context);
    if (reduced) {
      controller.stop();
    } else if (controller.value > 0 && !controller.isAnimating) {
      controller.reverse();
    }
  }

  @override
  void didUpdateWidget(covariant PlannerEntryFeedback oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.signal != oldWidget.signal && widget.signal > 0) {
      controller.value = 1;
      if (!reduced) controller.reverse();
    } else if (widget.signal == 0) {
      controller.value = 0;
    }
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    child: widget.child,
    builder:
        (context, child) => DecoratedBox(
          decoration: BoxDecoration(
            color: widget.color.withValues(
              alpha:
                  (reduced
                      ? (widget.signal > 0 ? 1.0 : 0.0)
                      : controller.value) *
                  .14,
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          child: child,
        ),
  );
}

class PlannerTaskControl extends StatefulWidget {
  const PlannerTaskControl({
    super.key,
    required this.value,
    required this.onChanged,
    this.busy = false,
  });
  final bool value, busy;
  final ValueChanged<bool>? onChanged;
  @override
  State<PlannerTaskControl> createState() => _PlannerTaskControlState();
}

class _PlannerTaskControlState extends State<PlannerTaskControl> {
  bool pressed = false;
  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: (_) => setState(() => pressed = true),
    onPointerUp: (_) => setState(() => pressed = false),
    onPointerCancel: (_) => setState(() => pressed = false),
    child: AnimatedScale(
      scale: pressed && !MediaQuery.disableAnimationsOf(context) ? .90 : 1,
      duration:
          MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : Duration(milliseconds: pressed ? 80 : 180),
      curve: Curves.easeOutCubic,
      child: SizedBox(
        width: 48,
        height: 48,
        child:
            widget.busy
                ? const Center(
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      semanticsLabel: 'Saving task on this device',
                    ),
                  ),
                )
                : Checkbox(
                  value: widget.value,
                  onChanged:
                      widget.onChanged == null
                          ? null
                          : (value) => widget.onChanged!(value!),
                ),
      ),
    ),
  );
}
