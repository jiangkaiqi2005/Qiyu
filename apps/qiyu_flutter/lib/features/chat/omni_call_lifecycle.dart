import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'local_chat_view_model.dart';
import 'omni_call_controller.dart';

/// 全应用的路由/前后台接线，通话与偏好判定仍由同一个 controller 持有。
class OmniCallLifecycle extends StatefulWidget {
  const OmniCallLifecycle({
    super.key,
    required this.router,
    required this.rootChatReady,
    required this.child,
  });

  final GoRouter router;
  final bool rootChatReady;
  final Widget child;

  @override
  State<OmniCallLifecycle> createState() => _OmniCallLifecycleState();
}

class _OmniCallLifecycleState extends State<OmniCallLifecycle>
    with WidgetsBindingObserver {
  late OmniCallController _call;
  bool _visible =
      WidgetsBinding.instance.lifecycleState == null ||
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
  bool _bound = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_bound) return;
    _bound = true;
    _call = context.read<OmniCallController>();
    widget.router.routerDelegate.addListener(_syncLocation);
    WidgetsBinding.instance.addObserver(this);
    _scheduleLocation();
  }

  @override
  void didUpdateWidget(OmniCallLifecycle oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.rootChatReady != widget.rootChatReady) _scheduleLocation();
  }

  void _scheduleLocation() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncLocation();
    });
  }

  void _syncLocation() {
    final path = widget.router.routerDelegate.currentConfiguration.uri.path;
    _call.updateLocation(
      onChat: path == '/chat' || (path == '/' && widget.rootChatReady),
      visible: _visible,
      sessionId: context.read<LocalChatViewModel>().sessionId,
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _visible = state == AppLifecycleState.resumed;
    _syncLocation();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.router.routerDelegate.removeListener(_syncLocation);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
