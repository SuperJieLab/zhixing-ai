import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:socratic_ai/core/engine/model_manager.dart';
import 'package:socratic_ai/core/models/available_model.dart';
import 'package:socratic_ai/core/theme.dart';
import 'package:socratic_ai/features/model_manager/providers/model_download_provider.dart';

/// 模型管理页
///
/// 展示可用模型列表 + 下载交互。
/// 页面内部通过 ChangeNotifierProvider 管理 DownloadProvider 生命周期。
/// 模型就绪状态从全局 ModelManager 读取。
class ModelManagePage extends StatelessWidget {
  const ModelManagePage({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => ModelDownloadProvider(),
      child: _ModelManageContent(),
    );
  }
}

class _ModelManageContent extends StatelessWidget {
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
    final downloadProvider = context.watch<ModelDownloadProvider>();
    final downloadState = downloadProvider.stateOf(model.id);
    final manager = context.watch<ModelManager>();
    final isActive = manager.activeModelId == model.id;
    final isDownloaded = manager.isDownloaded(model.id);

    // 优先显示全局就绪状态；其次看下载状态
    final state = (isActive || isDownloaded)
        ? const ModelDownloadState(status: DownloadStatus.completed, progress: 1.0)
        : downloadState;

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
                _buildAction(context, downloadProvider, state, isActive, isDownloaded),
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
  }

  Widget _buildAction(
    BuildContext context,
    ModelDownloadProvider provider,
    ModelDownloadState state,
    bool isActive,
    bool isDownloaded,
  ) {
    final manager = context.read<ModelManager>();

    // 正在下载
    if (state.status == DownloadStatus.downloading) {
      return TextButton(
        onPressed: () => provider.cancelDownload(model.id),
        child: const Text('取消', style: TextStyle(color: AppTheme.textSecondary)),
      );
    }

    // 已下载但非当前活跃 → 显示"切换使用"
    if (isDownloaded && !isActive) {
      return OutlinedButton.icon(
        onPressed: () => manager.switchToModel(model.id),
        icon: const Icon(Icons.swap_horiz, size: 18),
        label: const Text('使用'),
        style: OutlinedButton.styleFrom(
          foregroundColor: AppTheme.primary,
          side: const BorderSide(color: AppTheme.primary),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      );
    }

    // 当前活跃模型
    if (isActive) {
      return const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_circle, color: AppTheme.primary, size: 22),
          SizedBox(width: 4),
          Text('已就绪', style: TextStyle(color: AppTheme.primary, fontSize: 13)),
        ],
      );
    }

    // 未下载
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
  }
}
