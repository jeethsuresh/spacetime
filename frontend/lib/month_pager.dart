import 'dart:async';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Keeps month paging independent of the selected day and visible date range.
class MonthPager extends StatefulWidget {
  final DateTime month;
  final ValueChanged<DateTime> onMonthChanged;
  final Widget Function(DateTime month) builder;

  const MonthPager({
    super.key,
    required this.month,
    required this.onMonthChanged,
    required this.builder,
  });

  @override
  State<MonthPager> createState() => _MonthPagerState();
}

class _MonthPagerState extends State<MonthPager> {
  static const origin = 12000;
  late final anchor = DateTime.utc(widget.month.year, widget.month.month);
  late final controller = PageController(initialPage: origin, keepPage: false);
  Timer? scrollIdle;
  double scrollDelta = 0;
  bool scrolled = false;

  DateTime monthAt(int page) =>
      DateTime.utc(anchor.year, anchor.month + page - origin);
  int pageFor(DateTime month) =>
      origin + (month.year - anchor.year) * 12 + month.month - anchor.month;

  @override
  void didUpdateWidget(MonthPager oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (pageFor(oldWidget.month) == pageFor(widget.month)) return;
    // Header arrows, Today, and adjacent-month dates use the same pager.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !controller.hasClients) return;
      final target = pageFor(widget.month);
      if (controller.page!.round() != target) controller.jumpToPage(target);
    });
  }

  void pointerScroll(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final delta =
        event.scrollDelta.dx.abs() > event.scrollDelta.dy.abs()
            ? event.scrollDelta.dx
            : event.scrollDelta.dy;
    if (delta == 0) return;
    // Use either wheel axis so a mouse wheel works as well as a trackpad.
    // Descendant scrollables resolve first when the month grid overflows.
    // One burst advances one whole month instead of leaving a partial page.
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      scrollIdle?.cancel();
      scrollIdle = Timer(const Duration(milliseconds: 180), () {
        scrollDelta = 0;
        scrolled = false;
      });
      if (scrolled) return;
      scrollDelta += delta;
      if (scrollDelta.abs() < 36) return;
      scrolled = true;
      final target = controller.page!.round() + (scrollDelta > 0 ? 1 : -1);
      // A direct snap keeps the viewport listening throughout a wheel burst.
      // Driven PageView animations ignore child pointers, letting later wheel
      // events interrupt the snap through Scrollable's pixel-based handler.
      controller.jumpToPage(target.clamp(0, origin * 2));
    });
  }

  @override
  void dispose() {
    scrollIdle?.cancel();
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PageView.builder(
    key: const ValueKey('month-pager'),
    controller: controller,
    pageSnapping: true,
    itemCount: origin * 2 + 1,
    onPageChanged: (page) {
      if (page != pageFor(widget.month)) widget.onMonthChanged(monthAt(page));
    },
    itemBuilder:
        (context, page) => Listener(
          behavior: HitTestBehavior.opaque,
          onPointerSignal: pointerScroll,
          child: widget.builder(monthAt(page)),
        ),
  );
}
