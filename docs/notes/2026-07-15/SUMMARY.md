# 2026-07-15 总结

## 完成

### 一、Bonsai 27B 模型集成

1. **添加下载** — Bonsai 27B (1-bit, Q1_0) 加入 AvailableModel.available
   - 体积 3.8 GB，hf-mirror 镜像下载
   - Q1_0 格式已合入 llama.cpp 主线，但 llama_cpp_dart 版本可能偏旧

2. **ChatProvider seedHistory 重构** (`44b046c`)
   - 把 seed 从消息追加之后提前到之前，消除 `_messages.length - 2` 魔法数字
   - 改为直传 `_messages`

### 二、Bonsai 相关 bug 修复（3a22bab，6 项）

3. **模型列表状态** — 下载新模型后旧模型不再错误显示"下载"
   - ModelManager 新增 `_downloadedModelIds` 集合 + `isDownloaded()` + `switchToModel()`
   - ModelDownloadProvider `_initStates()` 启动时同步已下载状态
   - UI 三种状态：已就绪(活跃) / 使用(已下载) / 下载

4. **think 标签剥离** — Bonsai 输出 `<think>` / `<思考>` 导致 JSON 解析失败
   - 提取 `stripThinkTags()` 到 `core/think_tag_stripper.dart`
   - InsightService、GraphService、SocraticPrompter 统一使用

5. **GraphService JSON 截断** — maxTokens 3072→4096，新增截断补全兜底

6. **Token 估算同步** — 旧代码硬编码 2048，改为动态引用 `modelContextSize × 0.85`

7. **模型偏好持久化** — 写入 `model_preference.json`，启动恢复上次选择

8. **下载容错** — sizeBytes 修正为实际值，416 响应直接当完成

### 三、全仓库代码审查 + 清理（0c0be91，19 文件 +173/-353）

9. **死代码删除**
   - DialogueEngine 接口移除 `seedContext()` / `reset()`（+实现）
   - 删除 TopicProvider 整类（write-only，无消费者）
   - 删除 HistoryPage 空 initState、多余 async

10. **架构修复**
    - `seedHistory()` 提升到 DialogueEngine 接口，ChatProvider 消除类型转换
    - MindMapProvider 改用 ConversationService（不再直接 import Repository）
    - 零 feature 层文件直接 import Repository

11. **代码去重**
    - 节点颜色/类型标签 → GraphNode 静态方法
    - `_buildConversationText()` → 共享 `core/chat_utils.dart`
    - graph_painter 和 node_detail_sheet 删除 50+ 行重复 switch

12. **错误处理改进**
    - `_savePreference()` 加 try-catch
    - `clearError()` 加 notifyListeners
    - MindMapPage 空状态展示错误信息

13. **导入统一** — ChatProvider 相对导入 → 绝对 `package:socratic_ai/`

## 关键决策

- Bonsai 27B 标记为"实验性"，当前主要用 Qwen3.5-2B
- DialogueEngine 接口精简为 4 个方法：initialize / seedHistory / generateResponse / dispose
- 项目不再使用 TopicProvider，topic 直接走页面构造参数传递
- 修复思维图谱不持久化：ChatPage → InsightsPage 时补传 `graph: widget.conversation?.graph`，历史会话恢复后可复用 DB 缓存的图谱
