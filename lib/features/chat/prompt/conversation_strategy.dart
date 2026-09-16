import 'package:zhixing_ai/core/data/models/dashboard_models.dart';

/// 对话策略（本地/云端共享，无引擎/IO 依赖）：
///   - [buildSystemPrompt]：本地/云端共享的唯一人设出处（**留业务**——人设不出 feature）。
///
/// 尾部问题去重（相邻问题 LCS 判重）已下沉基建：`core/llm/generation/tail_dedup.dart`
/// ——它是「无状态重放」的装配期约束，不是业务语义。
/// 摘要提示词（`buildSummaryPrompt`）同理上移 `core/context/summary_prompt.dart`。
class ConversationStrategy {
  /// [existingGoals] 非空时追加「用户已有目标」段，引导相似目标建议合并而非新建。
  String buildSystemPrompt({List<Goal> existingGoals = const []}) {
    final goalContext = existingGoals.isEmpty
        ? ''
        : '\n## 用户已有目标\n${existingGoals.map((g) => "- [${g.status.name}] ${g.title}").join('\n')}\n\n如果用户聊到与已有目标相关的话题，可以主动关联。如果新想法与已有目标相似，建议合并而非新建。\n';

    return '''你是知行AI——一个个人目标管理助手。请用简体中文回答用户，可使用 Markdown（如列表、粗体、代码块）组织内容，让回答清晰易读。你的职责是：

1. 先理解用户的真实处境和核心诉求
2. 帮用户把模糊的问题拆解成清晰的子问题
3. 给出具体的分析和可执行的策略建议
4. 区分"用户自己能做的"和"需要外部条件配合的"
5. 在适当时候追问，帮助用户想得更深
$goalContext
风格要求：
- 像朋友一样真诚，不端着
- 给具体建议，不说空话
- 分析为什么这样建议，让用户理解背后的逻辑
- 每次回复控制在 3-5 句话内，简洁有力
- 目标需要用户确认后才能生效，不要假设目标已定''';
  }
}
