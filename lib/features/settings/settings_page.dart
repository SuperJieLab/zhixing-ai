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
            Consumer<SettingsProvider>(
              builder: (context, provider, _) => SwitchListTile(
                title: const Text('云端对话模式'),
                subtitle: const Text(
                  '开启后，对话内容直连你配置的模型 API（OpenAI 兼容），'
                  '不经过本应用服务端。\n默认关闭，本地模式全程不出设备。'
                  '切换后下次新对话生效。',
                ),
                value: provider.chatCloudMode,
                onChanged: (value) async {
                  // 门禁：三件套未配齐不允许开启（配置区见下方卡片）。
                  if (value && !provider.isCloudApiConfigured) {
                    await showDialog<void>(
                      context: context,
                      builder: (c) => AlertDialog(
                        title: const Text('请先配置云端 API'),
                        content: const Text(
                          '开启云端对话前，请在下方「云端模型 API」中'
                          '填写 API 地址、API Key 和模型名。',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(c),
                            child: const Text('知道了'),
                          ),
                        ],
                      ),
                    );
                    return;
                  }
                  if (value && !provider.chatCloudConsented) {
                    final agreed = await showDialog<bool>(
                      context: context,
                      builder: (c) => AlertDialog(
                        title: const Text('云端对话说明'),
                        content: const Text(
                          '开启云端对话后，你的对话内容将离开设备：直连发送至'
                          '你配置的模型服务商标识的服务器处理，本应用服务端'
                          '不经手。本地模式则全程在设备内完成，不出设备。'
                          '请确认你是否接受将对话内容上传至该服务商。',
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
                    await provider.setChatCloudConsented(true);
                  }
                  await provider.setChatCloudMode(value);
                },
              ),
            ),
            const _CloudApiConfigCard(),
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

/// 云端 BYOK 直连配置（API 地址 / Key / 模型名）。
/// 输入即持久化；三项齐全才允许开启云端模式开关（见上方门禁）。
class _CloudApiConfigCard extends StatefulWidget {
  const _CloudApiConfigCard();

  @override
  State<_CloudApiConfigCard> createState() => _CloudApiConfigCardState();
}

class _CloudApiConfigCardState extends State<_CloudApiConfigCard> {
  final _baseUrl = TextEditingController();
  final _apiKey = TextEditingController();
  final _modelName = TextEditingController();

  @override
  void initState() {
    super.initState();
    final provider = context.read<SettingsProvider>();
    _baseUrl.text = provider.cloudApiBaseUrl;
    _apiKey.text = provider.cloudApiKey;
    _modelName.text = provider.cloudModelName;
  }

  @override
  void dispose() {
    _baseUrl.dispose();
    _apiKey.dispose();
    _modelName.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('云端模型 API', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 4),
          const Text(
            'OpenAI 兼容端点；三项填写完整后才能开启云端对话模式。',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
          TextField(
            controller: _baseUrl,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: 'API 地址',
              hintText: 'https://api.deepseek.com',
            ),
            onChanged: (v) => context.read<SettingsProvider>().setCloudApiBaseUrl(v),
          ),
          TextField(
            controller: _apiKey,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              labelText: 'API Key',
              hintText: 'sk-...',
            ),
            onChanged: (v) => context.read<SettingsProvider>().setCloudApiKey(v),
          ),
          TextField(
            controller: _modelName,
            decoration: const InputDecoration(
              labelText: '模型名',
              hintText: 'deepseek-chat',
            ),
            onChanged: (v) => context.read<SettingsProvider>().setCloudModelName(v),
          ),
        ],
      ),
    );
  }
}
