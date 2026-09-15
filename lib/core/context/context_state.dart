/// 会话压缩状态（context 域；**实例由 ModelGateway 私有持有**，v2 起业务不碰）。
///
/// 采用「方案 A」形态：保留窗口**不被存下来**，只存覆盖游标 [k]——窗口恒为
/// `eligible[k..]`（全量列表的一条后缀），每轮由全量列表现算。⇒ 状态小到可
/// 序列化（将来能持久化 / 随会话迁移），且少一处可能与消息列表漂移的副本。
///
/// [lastEligibleLength] 与 [k] 的两条防御共同保证与「存完整窗口列表」等价：
/// ① 长度比上次**变短** → [reset]；② 游标越界 → [reset]。
class ContextState {
  /// 滚动摘要正文（首次为空串）。
  String summary;

  /// 覆盖游标：保留窗口起点在 eligible 中的下标（前 k 条已折进摘要 / 被丢弃）。
  int k;

  /// 上次装配时 eligible 的长度（历史变短检测）。
  int lastEligibleLength;

  /// 待执行的强制收缩条数（由策略的 `handleOverflow` 置位，下次装配生效）。
  int? pendingForceKeep;

  ContextState({
    this.summary = '',
    this.k = 0,
    this.lastEligibleLength = 0,
    this.pendingForceKeep,
  });

  /// 回到初始状态（新对话 / 重新初始化 / 历史回退）。
  void reset() {
    summary = '';
    k = 0;
    lastEligibleLength = 0;
    pendingForceKeep = null;
  }

  /// 仅重置窗口游标与挤出记账，**保留摘要正文**。
  ///
  /// 供后端模式切换使用（design D3）：两端窗口宽度不同（度量单位、预算都
  /// 不同），游标 `k` 跨模式语义会漂；而摘要正文与后端无关，可跨模式保留。
  void resetWindow() {
    k = 0;
    lastEligibleLength = 0;
    pendingForceKeep = null;
  }

  @override
  String toString() => 'ContextState(k: $k, summary: '
      '${summary.isEmpty ? 'none' : '${summary.length}字'}, '
      'lastEligibleLength: $lastEligibleLength)';
}
