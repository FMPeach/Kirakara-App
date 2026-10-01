part of '../../screens/controller_screen.dart';

class _KiraDialog extends StatelessWidget {
  const _KiraDialog({
    required this.title,
    required this.child,
    this.width = 430,
  });

  final String title;
  final Widget child;
  final double width;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xff17181c),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: KiraColors.lineStrong),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: width),
        child: Padding(
          padding: const EdgeInsets.all(26),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: KiraColors.cream,
                        fontSize: 28,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              child,
            ],
          ),
        ),
      ),
    );
  }
}

class _SlotProgress {
  const _SlotProgress({
    required this.state,
    required this.downloaded,
    required this.total,
    required this.complete,
  });
  final SlotState state;
  final int downloaded;
  final int total;
  final bool complete;
}

class _QueueItemRow extends StatelessWidget {
  const _QueueItemRow({
    required this.index,
    required this.song,
    required this.subtitle,
    required this.isCurrent,
    required this.progress,
    required this.failed,
    this.slotProgress,
    this.onRetry,
    this.onBump,
    this.onDelete,
  });

  final int index;
  final Song song;
  final String subtitle;
  final bool isCurrent;
  final PlaybackAssetProgress progress;
  final bool failed;
  final _SlotProgress? slotProgress;
  final VoidCallback? onRetry;
  final VoidCallback? onBump;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: isCurrent ? KiraColors.teal : KiraColors.surface2,
              borderRadius: BorderRadius.circular(10),
            ),
            child: isCurrent
                ? Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(
                      color: KiraColors.bg,
                      shape: BoxShape.circle,
                    ),
                  )
                : Text(
                    index.toString().padLeft(2, '0'),
                    style: const TextStyle(
                      color: KiraColors.amber,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  song.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: isCurrent
                        ? KiraColors.cream.withValues(alpha: 0.72)
                        : KiraColors.cream,
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: KiraColors.muted,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
          if (isCurrent)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _DownloadStatus(
                  progress: progress,
                  slotProgress: slotProgress,
                  failed: failed,
                ),
                const SizedBox(width: 10),
                Container(
                  height: 24,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  decoration: BoxDecoration(
                    color: const Color(0x2422c59b),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: const Color(0x4722c59b)),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.circle, size: 6, color: KiraColors.teal),
                      SizedBox(width: 4),
                      Text(
                        '播放中',
                        style: TextStyle(
                          color: KiraColors.teal,
                          fontSize: 12,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            )
          else ...[
            _DownloadStatus(
              progress: progress,
              slotProgress: slotProgress,
              failed: failed,
            ),
            const SizedBox(width: 10),
            if (onRetry != null)
              _QueueRetryButton(onTap: onRetry)
            else if (onBump != null)
              _QueueIconButton(
                icon: Icons.arrow_upward,
                color: KiraColors.muted,
                tooltip: '顶到下一首',
                onTap: onBump,
              ),
            if (onRetry == null && onBump != null && onDelete != null)
              const SizedBox(width: 6),
            if (onRetry == null && onDelete != null)
              _QueueIconButton(
                icon: Icons.close,
                color: KiraColors.muted,
                tooltip: '移除',
                onTap: onDelete,
              ),
          ],
        ],
      ),
    );
  }
}

class _DownloadStatus extends StatelessWidget {
  const _DownloadStatus({
    required this.progress,
    required this.failed,
    this.slotProgress,
  });

  final PlaybackAssetProgress progress;
  final bool failed;
  final _SlotProgress? slotProgress;

  @override
  Widget build(BuildContext context) {
    if (failed) {
      return const SizedBox(
        width: 112,
        child: Text(
          '下载失败',
          style: TextStyle(
            color: KiraColors.red,
            fontSize: 12,
            fontWeight: FontWeight.w900,
          ),
        ),
      );
    }

    // 下载完毕：所有资源完整缓存，不需要再显示进度条
    if (progress.isComplete) {
      return const SizedBox(width: 112);
    }

    final sp = slotProgress;
    // 队列中无任何下载活动 → 等待下载
    if (sp != null &&
        sp.state == SlotState.empty &&
        progress.knownAssets == 0) {
      return const SizedBox(
        width: 112,
        child: Text(
          '等待下载',
          style: TextStyle(
            color: KiraColors.muted,
            fontSize: 11,
            fontWeight: FontWeight.w800,
          ),
        ),
      );
    }

    final fraction = progress.fraction;
    final label = fraction == null
        ? '${progress.completeAssets}/${progress.assetCount}'
        : '${(fraction * 100).round()}%';
    final speed = progress.bytesPerSecond > 1
        ? '${_formatBytes(progress.bytesPerSecond.round())}/s'
        : '准备中…';

    return SizedBox(
      width: 112,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color:
                      progress.isComplete ? KiraColors.teal : KiraColors.amber,
                  fontSize: 11,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  speed,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                    color: KiraColors.muted,
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              minHeight: 4,
              value: fraction,
              backgroundColor: KiraColors.surface2,
              valueColor: const AlwaysStoppedAnimation<Color>(KiraColors.amber),
            ),
          ),
        ],
      ),
    );
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(kb >= 100 ? 0 : 1)}KB';
    final mb = kb / 1024;
    if (mb < 1024) return '${mb.toStringAsFixed(mb >= 100 ? 0 : 1)}MB';
    final gb = mb / 1024;
    return '${gb.toStringAsFixed(gb >= 100 ? 0 : 1)}GB';
  }
}

class _QueueRetryButton extends StatelessWidget {
  const _QueueRetryButton({required this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '重试下载',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            height: 38,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: KiraColors.surface2,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: KiraColors.lineStrong),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.refresh, size: 18, color: KiraColors.cream),
                SizedBox(width: 6),
                Text(
                  '重试',
                  style: TextStyle(
                    color: KiraColors.cream,
                    fontSize: 13,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _QueueIconButton extends StatelessWidget {
  const _QueueIconButton({
    required this.icon,
    required this.color,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final Color color;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Container(
            width: 38,
            height: 38,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: KiraColors.surface2,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: KiraColors.line),
            ),
            child: Icon(icon, size: 18, color: color),
          ),
        ),
      ),
    );
  }
}

BoxDecoration _surfaceDecoration({Color color = KiraColors.surface}) {
  return BoxDecoration(
    color: color,
    borderRadius: BorderRadius.circular(10),
    border: Border.all(color: KiraColors.line),
  );
}
