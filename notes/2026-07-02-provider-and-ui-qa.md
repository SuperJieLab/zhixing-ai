# Provider 注入策略 & 编译目标 & 声明式 UI

> 产生原因：实现 Day 1 工程搭建过程中，围绕 Provider 注入位置、macOS 目标运行、声明式 UI 概念展开的讨论。
> 记录时间：2026-07-02

---

## 1. Provider 的两种注入方式

Provider 有两种放置位置，选择取决于作用域需求：

| 注入位置 | 方式 | 适用场景 |
|:--|:--|:--|
| **main.dart 全局** | `MultiProvider` 包 `MaterialApp` | 跨页面共享（用户状态、主题） |
| **页面内部局部** | `ChangeNotifierProvider` 包当前页面 | 仅当前页面使用（对话消息、表单） |

### 为什么我们的项目两种都用

**TopicProvider → 全局注入**（main.dart/`MultiProvider`）
- 管理的「选了哪个话题」需要跨页面保持（来回导航时不变）
- 生命周期 = App 运行时间

**ChatProvider → 局部注入**（ChatPage 内部/`ChangeNotifierProvider`）
- 需要构造参数 `topic`（每次对话不同，全局注入做不到）
- 生命周期绑定页面：离开页面自动释放，避免内存泄漏
- 多次进入对话页会创建不同的 ChatProvider 实例（互不干扰）

### 局部注入的 ChatProvider，能访问全局的 TopicProvider 吗？

能。Provider 沿 Widget 树向上搜索，ChatProvider 在 TopicProvider 的下方，`context.watch<TopicProvider>()` 能找到祖先上的那个。

---

## 2. macOS vs iOS：编译目标

```
flutter run -d macos              flutter run -d ios
══════════════════                ════════════════
macOS 桌面窗口（.app）             iOS 模拟器/真机（.ipa）
需要 Xcode.app                   需要 Xcode.app
用鼠标操作                        用触摸操作
不支持 iOS 独有 API               支持所有 iOS API
```

### 当前环境

- 安装了 Xcode Command Line Tools → 有 `clang`、`git` 等基础工具
- **没有** Xcode.app → 缺 `xcodebuild` → `flutter run -d macos` 也报错
- 结论：**macOS 和 iOS 目标都需要完整的 Xcode.app**

装完 Xcode 后需执行：
```bash
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept
```

---

## 3. 声明式 UI

Flutter 是声明式 UI 框架。你描述「界面应该长什么样」，框架自己决定「怎么画、什么时候重画」。

```
命令式：一步一步告诉系统怎么做          声明式：描述最终想要的界面
══════════════════════════            ═══════════════════
tv.setText("你好")                     Text("你好")
tv.setBackgroundColor(WHITE)           Container(color: WHITE, child: ...)
layout.addView(tv)                     Column(children: [...])
```

### 关键映射

| HTML/CSS | Flutter Widget |
|:--|:--|
| `<div>` | Container / SizedBox |
| `display: flex; flex-direction: row` | Row() |
| `display: flex; flex-direction: column` | Column() |
| `flex: 1` | Expanded() |
| `padding: 16px` | Padding(padding: EdgeInsets.all(16)) |
| `<input>` | TextField |
| `onclick` | onTap / onPressed |

### 两种 Widget 类型

| StatelessWidget | StatefulWidget |
|:--|:--|
| 外观只取决于构造参数 | 内部持有可变数据（输入框、动画） |
| 我们项目：TopicCard / ChatBubble / ChatPage | 我们项目：ChatInput / ThinkingIndicator |
| 参数变了就重建 | 调用 setState() 时重建 |

详细 Widget 清单见 `notes/2026-07-02-flutter-widget-concepts.md`。
