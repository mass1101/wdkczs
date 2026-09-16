import 'package:flutter/material.dart';

/// 应用主题（对应逆向 primary_color：默认蓝 #1577FE，lightOrdark=1 时绿 #04BE02）
class AppTheme {
  static const Color blue = Color(0xFF1577FE);
  static const Color green = Color(0xFF04BE02);
  static const Color bg = Color(0xFFF5F6F8);

  static ThemeData build({bool greenTheme = false}) {
    final primary = greenTheme ? green : blue;
    return ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: primary,
        primary: primary,
        brightness: Brightness.light,
      ),
      scaffoldBackgroundColor: bg,
      appBarTheme: AppBarTheme(
        backgroundColor: primary,
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: true,
        titleTextStyle: const TextStyle(
          color: Colors.white,
          fontSize: 18,
          fontWeight: FontWeight.w600,
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: Color(0xFFEEEEEE),
        thickness: 0.5,
        space: 0.5,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: primary,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }
}

/// 分组卡片（左侧蓝色竖条 + 标题，对应逆向 uni-section）
class SectionCard extends StatelessWidget {
  final String? title;
  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;

  const SectionCard({
    super.key,
    this.title,
    required this.child,
    this.padding = const EdgeInsets.fromLTRB(12, 10, 12, 12),
    this.margin = const EdgeInsets.fromLTRB(10, 8, 10, 0),
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: margin,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0A000000),
            blurRadius: 2,
            offset: Offset(0, 1),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 10, 10, 4),
              child: Row(
                children: [
                  Container(
                    width: 4,
                    height: 14,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primary,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    title!,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF333333),
                    ),
                  ),
                ],
              ),
            ),
          Padding(padding: padding, child: child),
        ],
      ),
    );
  }
}

/// 蓝边白底圆角按钮（对应逆向页面右列按钮样式）
class ActionButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final Color? color;
  final Color? iconColor;
  final bool enabled;
  final bool stretch;

  const ActionButton({
    super.key,
    required this.label,
    this.icon,
    this.onTap,
    this.color,
    this.iconColor,
    this.enabled = true,
    this.stretch = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.primary;
    return Opacity(
      opacity: enabled ? 1 : 0.4,
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(6),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: enabled ? onTap : null,
          borderRadius: BorderRadius.circular(6),
          child: Ink(
            decoration: BoxDecoration(
              border: Border.all(color: c, width: 1),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Container(
              height: 34,
              width: stretch ? double.infinity : null,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                mainAxisSize: stretch ? MainAxisSize.max : MainAxisSize.min,
                mainAxisAlignment: stretch
                    ? MainAxisAlignment.spaceBetween
                    : MainAxisAlignment.start,
                children: [
                  if (icon != null) ...[
                    Icon(icon, size: 16, color: iconColor ?? c),
                    const SizedBox(width: 4),
                  ],
                  Text(label, style: TextStyle(fontSize: 13, color: c)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 连接状态横幅
class ConnectionBanner extends StatelessWidget {
  final bool connected;
  final String? deviceName;
  final VoidCallback? onConnect;
  final VoidCallback? onDisconnect;

  const ConnectionBanner({
    super.key,
    required this.connected,
    this.deviceName,
    this.onConnect,
    this.onDisconnect,
  });

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Container(
      color: connected ? const Color(0xFFE8F4FF) : const Color(0xFFF5F5F5),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Icon(
            connected ? Icons.link : Icons.link_off,
            size: 16,
            color: connected ? primary : Colors.grey,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              connected
                  ? '已连接${deviceName == null ? '' : '：$deviceName'}'
                  : '未连接设备',
              style: TextStyle(
                fontSize: 13,
                color: connected ? primary : Colors.grey,
              ),
            ),
          ),
          if (connected && onDisconnect != null)
            GestureDetector(
              onTap: onDisconnect,
              child: const Text(
                '断开',
                style: TextStyle(fontSize: 13, color: Colors.grey),
              ),
            )
          else if (!connected && onConnect != null)
            GestureDetector(
              onTap: onConnect,
              child: Text(
                '去连接',
                style: TextStyle(fontSize: 13, color: primary),
              ),
            ),
        ],
      ),
    );
  }
}

/// 颜色圆点选择行（选中项描边 + 勾）
class ColorPickerRow extends StatelessWidget {
  final List<int> colors;
  final int selected;
  final ValueChanged<int> onChange;
  final double size;

  const ColorPickerRow({
    super.key,
    required this.colors,
    required this.selected,
    required this.onChange,
    this.size = 28,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: colors.map((c) {
        final sel = c == selected;
        return GestureDetector(
          onTap: () => onChange(c),
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: Color(c),
              shape: BoxShape.circle,
              border: Border.all(
                color: sel
                    ? Theme.of(context).colorScheme.primary
                    : Colors.transparent,
                width: 2,
              ),
            ),
            child: sel
                ? const Icon(Icons.check, color: Colors.white, size: 16)
                : null,
          ),
        );
      }).toList(),
    );
  }
}

/// 密钥卡片行（label + 值 + 操作图标）
class KeyCard extends StatelessWidget {
  final String label;
  final String value;
  final VoidCallback? onList;
  final VoidCallback? onDownload;
  final VoidCallback? onDelete;
  final VoidCallback? onRefresh;

  const KeyCard({
    super.key,
    required this.label,
    required this.value,
    this.onList,
    this.onDownload,
    this.onDelete,
    this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F9FC),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFFE5EAF1)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 56,
            child: Text(
              label,
              style: const TextStyle(fontSize: 13, color: Color(0xFF666666)),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                fontSize: 12,
                color: Color(0xFF333333),
                letterSpacing: 0.5,
              ),
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (onList != null)
            IconButton(
              onPressed: onList,
              icon: Icon(Icons.list, size: 18, color: primary),
            ),
          if (onDownload != null)
            IconButton(
              onPressed: onDownload,
              icon: Icon(Icons.download, size: 18, color: primary),
            ),
          if (onRefresh != null)
            IconButton(
              onPressed: onRefresh,
              icon: Icon(Icons.refresh, size: 18, color: primary),
            ),
          if (onDelete != null)
            IconButton(
              onPressed: onDelete,
              icon: Icon(Icons.close, size: 18, color: Colors.grey),
            ),
        ],
      ),
    );
  }
}

/// 圆角分段选择按钮（对齐 CU ToggleButtonsWrapper）
/// 选项过窄时整体缩小，保证不换行
class ToggleButtonsWrapper extends StatelessWidget {
  final List<bool> isSelected;
  final List<String> children;
  final ValueChanged<int> onPressed;
  final Color? selectedColor;

  const ToggleButtonsWrapper({
    super.key,
    required this.isSelected,
    required this.children,
    required this.onPressed,
    this.selectedColor,
  });

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return FittedBox(
      alignment: Alignment.centerRight,
      fit: BoxFit.scaleDown,
      child: ToggleButtons(
        direction: Axis.horizontal,
        borderRadius: BorderRadius.all(const Radius.circular(32)),
        onPressed: onPressed,
        isSelected: isSelected,
        selectedBorderColor: primary,
        selectedColor: selectedColor ?? primary,
        color: Colors.grey.shade600,
        constraints: const BoxConstraints(minWidth: 44, minHeight: 34),
        children: [for (final c in children) Text(c)],
      ),
    );
  }
}
