import 'package:flutter/material.dart';
import 'package:socratic_ai/core/constants.dart';
import 'package:socratic_ai/core/theme.dart';

/// 话题卡片组件
///
/// 在话题选择页面中展示一个可点击的话题卡片。
/// 卡片包含三个部分：
/// - 左侧：emoji 图标（在圆角方形容器内）
/// - 中间：标题 + 描述（纵向排列）
/// - 右侧：向右箭头（暗示可点击进入）
///
/// ## 使用方式
/// ```dart
/// TopicCard(
///   topic: AppConstants.presetTopics[0],  // 传入一个话题数据
///   onTap: (topic) => print('选了 ${topic.title}'),  // 点击回调
/// )
/// ```
///
/// ## StatelessWidget vs StatefulWidget
/// 这里继承 StatelessWidget，因为卡片的外观只取决于传入的 topic 参数，
/// 不需要自己管理可变状态。选了什么话题由外层的 TopicProvider 管理，
/// TopicCard 只负责「展示」和「通知点击」。
class TopicCard extends StatelessWidget {
  /// 要展示的话题数据（图标、标题、描述）
  final TopicItem topic;

  /// 用户点击卡片时的回调
  ///
  /// [void Function(TopicItem)?] 中的 ? 表示这个回调是可选的 ——
  /// 如果不传 onTap，点击卡片不会有任何反应。
  final void Function(TopicItem)? onTap;

  /// 构造函数
  ///
  /// const 表示编译时常量，Flutter 可以复用已创建的 Widget，提升性能。
  /// super.key 是 Flutter 的 Widget 标识机制，让框架能识别同一位置的 Widget 是否变化。
  const TopicCard({super.key, required this.topic, this.onTap});

  /// build() 是 StatelessWidget 的核心方法
  ///
  /// 每次 Flutter 需要重新绘制时会调用 build()，返回一个 Widget 树。
  /// [context] 包含了 Widget 在树中的位置信息、主题、MediaQuery 等。
  @override
  Widget build(BuildContext context) {
    // 从 context 获取当前主题，这样 Text 的样式就会自动匹配我们配置的主题色
    final theme = Theme.of(context);

    // 点击话题后跳转到对话页面
    void handleTap() {
      if (onTap != null) {
        // 安全调用：如果 onTap 不为 null 才执行
        onTap!(topic);
      }
    }

    return Padding(
      // 外边距：卡片之间的间距
      // EdgeInsets.symmetric(horizontal: 20, vertical: 6)
      //   → 左右各 20px，上下各 6px
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),

      child: Material(
        // Material 包裹让卡片拥有点击水波纹效果（InkWell）
        // 这是 Material Design 的标准交互反馈
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          // InkWell 提供水波纹点击反馈
          onTap: handleTap,
          borderRadius: BorderRadius.circular(16),

          child: Padding(
            // 内边距：卡片内容与边框的距离
            padding: const EdgeInsets.all(20),

            child: Row(
              // Row 从左到右排列子组件

              children: [
                // ── 左侧：emoji 图标容器 ──
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    // 暖白底色，让 emoji 更突出
                    color: AppTheme.surface,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Center(
                    // Center 让 Text 在容器内居中
                    child: Text(
                      topic.icon,
                      style: const TextStyle(fontSize: 24),
                    ),
                  ),
                ),

                // SizedBox 是不可见的占位空间，16px 的间距
                const SizedBox(width: 16),

                // ── 中间：标题 + 描述 ──
                // Expanded 让这一列占据 Row 里剩余的所有空间，
                // 这样右侧的箭头就不会被挤压
                Expanded(
                  child: Column(
                    // crossAxisAlignment 控制垂直方向的对齐方式
                    // CrossAxisAlignment.start = 左对齐
                    crossAxisAlignment: CrossAxisAlignment.start,

                    // mainAxisSize.min 让 Column 只占用子元素所需的实际高度，
                    // 而不是撑满整个父容器
                    mainAxisSize: MainAxisSize.min,

                    children: [
                      // 标题
                      Text(
                        topic.title,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600, // 字体加粗
                        ),
                      ),

                      const SizedBox(height: 4),

                      // 描述
                      Text(
                        topic.description,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: AppTheme.textSecondary, // 弱化的文字颜色
                        ),
                      ),
                    ],
                  ),
                ),

                // ── 右侧：向右箭头 ──
                const Icon(
                  Icons.chevron_right,
                  color: AppTheme.textSecondary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
