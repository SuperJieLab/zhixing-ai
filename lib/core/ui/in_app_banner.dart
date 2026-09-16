import 'dart:async';

import 'package:flutter/material.dart';

/// 应用内推送横幅（顶部浮层）
///
/// 通过 [Overlay] 在屏幕顶部滑出一个独立卡片：盖在主视图之上、**不挤压**主视图
/// （区别于 SnackBar 从底部上滑、MaterialBanner 会把内容顶下去）。
/// 多个推送到达时排队依次展示；点击或 4s 后自动消失。
class InAppBanner {
  InAppBanner._();

  static final List<_BannerRequest> _queue = [];
  static bool _showing = false;

  /// [body] 空串即无正文行（[PushMessage.body] 已在解析层兜空）。
  static void show(OverlayState overlay,
      {required String title, String body = ''}) {
    _queue.add(_BannerRequest(overlay, title, body));
    if (!_showing) _showNext();
  }

  static void _showNext() {
    if (_queue.isEmpty) {
      _showing = false;
      return;
    }
    _showing = true;
    final req = _queue.removeAt(0);
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _TopBanner(
        title: req.title,
        body: req.body,
        onDismiss: () {
          entry.remove();
          _showNext();
        },
      ),
    );
    req.overlay.insert(entry);
  }
}

class _BannerRequest {
  final OverlayState overlay;
  final String title;
  final String body;
  _BannerRequest(this.overlay, this.title, this.body);
}

class _TopBanner extends StatefulWidget {
  final String title;
  final String body;
  final VoidCallback onDismiss;
  const _TopBanner({
    required this.title,
    required this.body,
    required this.onDismiss,
  });

  @override
  State<_TopBanner> createState() => _TopBannerState();
}

class _TopBannerState extends State<_TopBanner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 280),
  );
  late final Animation<Offset> _slide = Tween<Offset>(
    begin: const Offset(0, -1.2),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic));
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _ctrl.forward();
    _timer = Timer(const Duration(seconds: 4), dismiss);
  }

  void dismiss() {
    _timer?.cancel();
    _ctrl.reverse().then((_) => widget.onDismiss());
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const background = Color(0xFFF2F2F7);
    const titleColor = Color(0xFF1C1C1E);
    const bodyColor = Color(0xFF636366);

    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        top: true,
        bottom: false,
        child: SlideTransition(
          position: _slide,
          child: GestureDetector(
            onTap: dismiss,
            behavior: HitTestBehavior.translucent,
            child: Container(
              margin: const EdgeInsets.fromLTRB(10, 6, 10, 0),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: background,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.12),
                    blurRadius: 18,
                    offset: const Offset(0, 6),
                    spreadRadius: -2,
                  ),
                ],
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primary,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(
                      Icons.notifications_none,
                      size: 20,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: titleColor,
                            height: 1.25,
                            decoration: TextDecoration.none,
                          ),
                        ),
                        if (widget.body.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              widget.body,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w400,
                                color: bodyColor,
                                height: 1.3,
                                decoration: TextDecoration.none,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: dismiss,
                    behavior: HitTestBehavior.opaque,
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.05),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.close,
                        size: 14,
                        color: Color(0xFF8E8E93),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
