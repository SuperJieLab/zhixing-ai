import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:socratic_ai/core/engine/model_manager.dart';
import 'package:socratic_ai/core/models/available_model.dart';
import 'package:socratic_ai/core/theme.dart';

/// 模型管理页
///
/// 展示可用模型列表 + 下载交互。
/// 当前 APP 只有一个活跃模型，下载完成即自动启用。
class ModelManagePage extends StatelessWidget {
  const ModelManagePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('模型管理'),
        backgroundColor: AppTheme.background,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
      ),
      backgroundColor: AppTheme.background,
      body: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: AvailableModel.available.length,
        itemBuilder: (context, index) {
          final model = AvailableModel.available[index];
          return _ModelCard(model: model);
        },
      ),
    );
  }
}

class _ModelCard extends StatelessWidget {
  final AvailableModel model;

  const _ModelCard({required this.model});

  @override
  Widget build(BuildContext context) {
    return Consumer<ModelDownloadProvider>(
      builder: (context, provider, _) {
        final state = provider.stateOf(model.id);

        return Card(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: Colors.grey.shade200),
          ),
          color: Colors.white,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 标题行
                Row(
                  children: [
                    const Icon(Icons.memory, size: 28, color: AppTheme.primary),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            model.name,
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            model.description,
                            style: const TextStyle(
                              fontSize: 13,
                              color: AppTheme.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    _buildAction(context, provider, state),
                  ],
                ),

                const SizedBox(height: 10),

                // 模型详情
                Text(
                  '${model.quant} 量化 · ${ModelDownloadProvider.formatBytes(model.sizeBytes)}',
                  style: const TextStyle(fontSize: 12, color: Colors.black38),
                ),

                // 下载进度条
                if (state.status == DownloadStatus.downloading) ...[
                  const SizedBox(height: 12),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: state.progress > 0 ? state.progress : null,
                      minHeight: 6,
                      backgroundColor: Colors.grey.shade200,
                      valueColor: const AlwaysStoppedAnimation(AppTheme.primary),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '${(state.progress * 100).toInt()}%',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      Text(
                        state.speedText,
                        style: const TextStyle(fontSize: 12, color: Colors.black45),
                      ),
                      Text(
                        state.etaText,
                        style: const TextStyle(fontSize: 12, color: Colors.black45),
                      ),
                    ],
                  ),
                ],

                // 失败消息
                if (state.status == DownloadStatus.failed && state.error != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    state.error!,
                    style: const TextStyle(fontSize: 12, color: AppTheme.error),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],

                // 完成提示
                if (state.status == DownloadStatus.completed) ...[
                  const SizedBox(height: 4),
                  const Text(
                    '模型已就绪，可以开始对话了',
                    style: TextStyle(fontSize: 12, color: AppTheme.primary),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildAction(
    BuildContext context,
    ModelDownloadProvider provider,
    ModelDownloadState state,
  ) {
    switch (state.status) {
      case DownloadStatus.idle:
      case DownloadStatus.cancelled:
      case DownloadStatus.failed:
        return OutlinedButton.icon(
          onPressed: () => provider.startDownload(model),
          icon: const Icon(Icons.download, size: 18),
          label: const Text('下载'),
          style: OutlinedButton.styleFrom(
            foregroundColor: AppTheme.primary,
            side: const BorderSide(color: AppTheme.primary),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        );

      case DownloadStatus.downloading:
        return TextButton(
          onPressed: () => provider.cancelDownload(model.id),
          child: const Text('取消', style: TextStyle(color: AppTheme.textSecondary)),
        );

      case DownloadStatus.completed:
        return const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle, color: AppTheme.primary, size: 22),
            SizedBox(width: 4),
            Text('已就绪', style: TextStyle(color: AppTheme.primary, fontSize: 13)),
          ],
        );
    }
  }
}
