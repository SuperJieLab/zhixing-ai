import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:socratic_ai/core/constants.dart';
import 'package:socratic_ai/core/theme.dart';
import 'package:socratic_ai/features/topics/widgets/topic_card.dart';
import 'package:socratic_ai/core/snackbar_throttle.dart';
import 'package:socratic_ai/features/chat/chat_page.dart';
import 'package:socratic_ai/core/engine/model_manager.dart';
import 'package:socratic_ai/features/model_manager/model_manage_page.dart';
import 'package:socratic_ai/features/history/history_page.dart';

/// 话题选择页面（首页）
///
/// 用户打开 App 看到的第一个页面。
/// 提供两种开始对话的方式：
/// 1. **预设话题**：点击 5 个预设话题卡片中的任意一个
/// 2. **自定义话题**：在底部输入框中输入自己想聊的内容
///
/// ## 页面职责
/// - 展示 App 名称和标语
/// - 列出 5 个预设话题卡片
/// - 提供自定义话题输入框
/// - 点击话题后跳转到 ChatPage
///
/// ## Provider 监听
/// 通过 `context.watch<TopicProvider>()` 监听选中状态。
/// watch 和 read 的区别：
/// - watch：订阅变化，widget 会在状态变化时自动重建
/// - read：只读一次，不会触发重建（用于 onTap 回调中）
class TopicSelectionPage extends StatelessWidget {
  const TopicSelectionPage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // 监听模型就绪状态，确保 checkLocalModels() 完成后自动重建
    final hasModel = context.watch<ModelManager>().hasModel;

    return Scaffold(
      // ============================================================
      // AppBar（顶部导航栏）
      // ============================================================
      appBar: AppBar(
        // 不需要标题文字，标题在页面 body 里
        title: null,

        // 固定背景色为暖白，覆盖 M3 默认的滚动变色行为
        backgroundColor: AppTheme.background,

        // 禁用 M3 的 surfaceTintColor（默认会根据滚动叠加主题色）
        surfaceTintColor: Colors.transparent,

        // 禁用滚动时的阴影变化
        scrolledUnderElevation: 0,

        // actions 是 AppBar 右侧的按钮列表
        actions: [
          // 模型管理入口
          IconButton(
            icon: const Icon(Icons.memory, color: AppTheme.textSecondary),
            tooltip: '模型管理',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const ModelManagePage(),
                ),
              );
            },
          ),
          // 历史记录按钮
          IconButton(
            icon: const Icon(Icons.history, color: AppTheme.textSecondary),
            tooltip: '历史对话', // 长按时的提示文字
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const HistoryPage(),
                ),
              );
            },
          ),
        ],
      ),

      // ============================================================
      // Body（页面主体）
      // ============================================================
      // SafeArea 确保内容不会被刘海屏、底部横条等遮挡
      body: SafeArea(
        child: Column(
          // CrossAxisAlignment.start = 子元素左对齐
          crossAxisAlignment: CrossAxisAlignment.start,

          children: [
            // ── App 名称 ──
            const Padding(
              padding: EdgeInsets.fromLTRB(24, 16, 24, 8),
              child: Text(
                AppConstants.appName, // 'Socratic AI'
                style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.textPrimary,
                  letterSpacing: -0.5, // 字间距微调，更紧凑
                ),
              ),
            ),

            // ── App 标语 ──
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                AppConstants.appTagline, // '帮你想清楚'
                style: TextStyle(
                  fontSize: 16,
                  color: AppTheme.textSecondary,
                ),
              ),
            ),

            const SizedBox(height: 12),

            // ── 分区标题："选择一个话题开始对话" ──
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
              child: Text(
                '选择一个话题开始对话',
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),

            const SizedBox(height: 8),

            // ============================================================
            // 话题列表（可滚动）
            // ============================================================
            // Expanded 让 ListView 占据 Column 剩余的垂直空间，
            // 确保输入框始终在底部可见
            Expanded(
              child: ListView(
                // ListView 的额外底部内边距，让最后一个元素不被遮挡
                padding: const EdgeInsets.only(bottom: 16),

                children: [
                  // ...AppConstants.presetTopics.map(...)
                  // 遍历 5 个预设话题，为每个话题创建一个 TopicCard
                  // ... 展开运算符把 map 返回的列表打平成一串 children
                  ...AppConstants.presetTopics.map(
                    (topic) => TopicCard(
                      topic: topic,
                      // 用户点击卡片时的处理逻辑
                      onTap: (t) {
                        if (!hasModel) {
                          _showModelRequiredSnackBar(context);
                          return;
                        }
                        // 跳转到对话页面
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => ChatPage(topic: t.title),
                          ),
                        );
                      },
                    ),
                  ),

                  const SizedBox(height: 16),

                  // ── 自定义话题区域标题 ──
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 24),
                    child: Text(
                      '或者，说说你想聊的',
                      style: TextStyle(
                        fontSize: 14,
                        color: AppTheme.textSecondary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),

                  const SizedBox(height: 12),

                  // ── 自定义话题输入框 ──
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: TextField(
                      // onChanged：每次输入内容变化时触发
                      onChanged: (_) {},

                      // onSubmitted：用户按回车键时触发
                      onSubmitted: (value) {
                        if (!hasModel) {
                          _showModelRequiredSnackBar(context);
                          return;
                        }
                        final trimmed = value.trim();
                        // 只有非空输入才跳转
                        if (trimmed.isNotEmpty) {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => ChatPage(topic: trimmed),
                            ),
                          );
                        } else {
                          SnackBarThrottle.show(context, '请输入话题内容');
                        }
                      },

                      // decoration 控制输入框的外观
                      decoration: InputDecoration(
                        hintText: '✍️ 输入你的话题...',
                        hintStyle: const TextStyle(
                          color: AppTheme.textSecondary,
                        ),

                        // 背景
                        filled: true,
                        fillColor: Colors.white,

                        // 内容内边距
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 16,
                        ),

                        // 默认边框（未选中）
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide: const BorderSide(
                            color: Color(0xFFE8E4DF), // 暖灰边框
                          ),
                        ),

                        // 非选中时的边框
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide: const BorderSide(
                            color: Color(0xFFE8E4DF),
                          ),
                        ),

                        // 选中（获得焦点）时的边框
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide: const BorderSide(
                            color: AppTheme.primary, // 鼠尾草绿
                            width: 1.5, // 比默认粗一点，暗示聚焦状态
                          ),
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
    );
  }
}

void _showModelRequiredSnackBar(BuildContext context) {
  ScaffoldMessenger.of(context).hideCurrentSnackBar();
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: const Text('请先下载 AI 模型'),
      action: SnackBarAction(
        label: '去下载',
        onPressed: () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const ModelManagePage()),
          );
        },
      ),
      duration: const Duration(seconds: 4),
    ),
  );
}
