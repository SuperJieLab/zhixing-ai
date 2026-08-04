import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:zhixing_ai/features/settings/providers/settings_provider.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<SettingsProvider>(
      create: (_) => SettingsProvider(),
      child: Scaffold(
        appBar: AppBar(
          title: const Text('设置'),
        ),
        body: ListView(
          children: [
            Consumer<SettingsProvider>(
              builder: (context, provider, _) => SwitchListTile(
                title: const Text('GPU 加速'),
                subtitle: const Text(
                  '开启后模型全量卸载到 GPU（Metal），真机推理更快；'
                  '模拟器上 Metal 后端可能初始化失败，可关闭改用纯 CPU。',
                ),
                value: provider.useGpuAcceleration,
                onChanged: (value) => provider.setUseGpuAcceleration(value),
              ),
            ),
            const Divider(height: 1),
            Consumer<SettingsProvider>(
              builder: (context, provider, _) => SwitchListTile(
                title: const Text('AI 优化推送'),
                subtitle: const Text(
                  '开启后，服务端使用 AI 分析你的目标数据，生成更智能的推送提醒。\n'
                  '对话原文不会被上传。',
                ),
                value: provider.useAiOptimizedPush,
                onChanged: (value) async {
                  if (value && !provider.aiPushConsented) {
                    final agreed = await showDialog<bool>(
                      context: context,
                      builder: (c) => AlertDialog(
                        title: const Text('AI 优化推送说明'),
                        content: const Text(
                          '开启后将上传目标标题、分类、截止日期和策略描述到服务端，'
                          '用于 AI 分析推送时机。对话原文不会被上传。数据在服务端'
                          '处理完成后即丢弃，不会持久化存储。',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(c, false),
                            child: const Text('取消'),
                          ),
                          TextButton(
                            onPressed: () => Navigator.pop(c, true),
                            child: const Text('同意并开启'),
                          ),
                        ],
                      ),
                    );
                    if (agreed != true) return;
                    await provider.setAiPushConsented(true);
                  }
                  await provider.setUseAiOptimizedPush(value);
                },
              ),
            ),
            const Divider(height: 1),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 24),
              child: Text(
                '修改后将在下次加载模型时生效，当前对话不受影响。',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
