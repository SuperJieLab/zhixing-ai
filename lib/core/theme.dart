import 'package:flutter/material.dart';

/// 应用主题配置类
///
/// 定义整个 App 的视觉风格，包括颜色体系、字体层级、卡片样式等。
/// 基于 Material 3 设计规范，配色灵感来自「鼠尾草绿 + 暖棕 + 暖金」，
/// 传递冷静、温暖、有品质感的视觉感受。
///
/// 使用方式：在 MaterialApp 中传入
/// ```dart
/// MaterialApp(theme: AppTheme.lightTheme)
/// ```
class AppTheme {
  // ============================================================
  // 核心色板 — 整个 App 的颜色 DNA
  // ============================================================

  /// 主色调：鼠尾草绿
  /// 用于按钮、选中态、强调元素 — 传递冷静、理性的感觉
  static const Color primary = Color(0xFF5B6D5B);

  /// 次要色：暖棕色
  /// 用于副标题、次要按钮 — 传递温暖、人性化的感觉
  static const Color secondary = Color(0xFF8B7355);

  /// 表面色：暖白色
  /// 用于卡片、对话框背景 — 类似纸张的暖白，比纯白更有质感
  static const Color surface = Color(0xFFF5F0EB);

  /// 背景色：近白色
  /// 用于整个页面的底层背景 — 比 surface 更浅一层
  static const Color background = Color(0xFFFAFAF8);

  /// 强调色：暖金色
  /// 用于高亮、徽章、特殊标记 — 增添品质感
  static const Color accent = Color(0xFFD4A574);

  // ============================================================
  // 文字颜色
  // ============================================================

  /// 主要文字颜色 — 深灰色，比纯黑更柔和
  static const Color textPrimary = Color(0xFF2C2C2C);

  /// 次要文字颜色 — 中灰色，用于说明文字、占位符
  static const Color textSecondary = Color(0xFF6B6B6B);

  // ============================================================
  // 亮色主题配置
  // ============================================================

  /// 返回一个完整的亮色主题数据对象 [ThemeData]
  ///
  /// 这是一个 getter（get 属性），每次访问都会返回同一个主题配置。
  /// Flutter 的 MaterialApp 接收这个 ThemeData 后，
  /// 它的所有子 Widget 都能通过 Theme.of(context) 获取到这些颜色和样式。
  static ThemeData get lightTheme {
    return ThemeData(
      // 启用 Material 3 设计规范（Flutter 3.x 的默认风格）
      // Material 3 相比 M2 有更柔和的圆角、更自然的颜色系统
      useMaterial3: true,

      // ColorScheme.fromSeed 会根据一个「种子颜色」自动生成一套协调的色板
      // 比如从 primary（鼠尾草绿）自动推导出浅绿、深绿等变体，
      // 用于不同状态的按钮、文本、背景等场景
      colorScheme: ColorScheme.fromSeed(
        seedColor: primary,
        brightness: Brightness.light, // 亮色模式
        surface: surface,
      ),

      // 页面底层背景色
      scaffoldBackgroundColor: background,

      // ============================================================
      // 顶部导航栏样式
      // ============================================================
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent, // 透明背景，融入页面
        elevation: 0, // 无阴影 — 极简风格
        centerTitle: false, // 标题靠左（iOS 风格）
        titleTextStyle: TextStyle(
          color: textPrimary,
          fontSize: 20,
          fontWeight: FontWeight.w600, // 半粗体
        ),
      ),

      // ============================================================
      // 文字层级体系
      // ============================================================
      // Flutter 的 TextTheme 定义了多个语义化的文字样式，
      // 不同 Widget 会按约定自动选用对应的样式。
      // 比如 AppBar 默认用 titleLarge，body 文本用 bodyLarge。
      textTheme: const TextTheme(
        // 大标题 — 用于页面主标题
        headlineLarge: TextStyle(
          fontSize: 28,
          fontWeight: FontWeight.w700, // 粗体
          color: textPrimary,
          letterSpacing: -0.5, // 字间距略收紧，大标题更紧凑
        ),

        // 中等标题 — 用于分区标题
        headlineMedium: TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.w600,
          color: textPrimary,
        ),

        // 正文大 — 用于段落文本
        bodyLarge: TextStyle(
          fontSize: 16,
          color: textPrimary,
          height: 1.5, // 行高 1.5 倍，阅读舒适
        ),

        // 正文中 — 用于辅助文本、说明
        bodyMedium: TextStyle(
          fontSize: 14,
          color: textSecondary,
          height: 1.4,
        ),
      ),

      // ============================================================
      // 卡片样式 — 全局统一的卡片外观
      // ============================================================
      cardTheme: CardThemeData(
        elevation: 0, // 无阴影 — 扁平化设计
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16), // 16px 圆角
        ),
        color: Colors.white,
        // surfaceTintColor 设为透明，避免 Material 3 自动叠加着色
        surfaceTintColor: Colors.transparent,
      ),
    );
  }
}
