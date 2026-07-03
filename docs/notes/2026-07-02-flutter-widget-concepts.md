# Flutter 核心 Widget 概念速查

> 产生原因：在实现 Socratic AI 的 UI 组件时，需要理解 Flutter 声明式 UI 中各种 Widget 的作用和选择标准。
> 记录时间：2026-07-02

---

## 1. 声明式 UI 的本质

Flutter 是声明式框架：你描述「界面应该长什么样」，框架自己决定「怎么画、什么时候重画」。

```
命令式（传统）：                     声明式（Flutter）：
TextView tv = new TextView();       Text('你好',
tv.setText('你好');                   style: TextStyle(color: Colors.black))
tv.setBackgroundColor(BLACK);
```

每次状态变化时，Flutter 重新执行 `build()`，比较新旧 Widget 树，只更新变化的像素。不会出现「忘记调用 updateUI」的 Bug。

---

## 2. Widget 分类总览

Flutter 所有可见/可操作的组件都是 Widget，按职责分为五层：

```
页面结构（骨架）
├── Scaffold     — 页面骨架（body + appBar + bottomBar）
├── AppBar       — 顶部导航栏
├── SafeArea     — 避开刘海、底部横条
└── ListView     — 滚动列表（.builder 懒加载）

布局容器（排布子元素）
├── Row          — 水平排列
├── Column       — 垂直排列
├── Expanded     — 占据 Row/Column 剩余空间
├── Padding      — 外边距/内边距
└── SizedBox     — 固定尺寸的间隙

样式容器（给子元素加外观）
├── Container    — 万能盒子（宽高+内边距+装饰+子组件）
├── Material     — 提供裁剪区域（搭配 InkWell 用水波纹）
├── InkWell      — Material Design 水波纹点击反馈
└── Center       — 子元素居中

基础组件（叶子节点）
├── Text         — 文字渲染
├── TextField    — 文本输入（需要 TextEditingController）
├── IconButton   — 图标按钮
└── CircleAvatar — 圆形头像

两种 Widget 类型
├── StatelessWidget — 无状态，外观只取决于输入参数
└── StatefulWidget  — 有状态，内部持有可变数据
```

---

## 3. 页面结构层

### Scaffold — 页面骨架

```dart
Scaffold(
  appBar: AppBar(title: Text('标题')),
  body: Column(...),
)
```

每个页面一个 Scaffold，类比 `<body> + <header>`。提供标准的三块区域框架。

### AppBar — 顶部导航栏

自动包含返回箭头（有上一页时）、标题文字、右侧操作按钮 (`actions`)。

### SafeArea — 安全区域

包裹内容后自动适配 iPhone 刘海、底部横条。不包的话按钮可能被系统 UI 遮挡。

### ListView / ListView.builder — 滚动列表

```dart
ListView.builder(
  itemCount: 100,
  itemBuilder: (context, index) => Text('第 $index 条'),
)
```

`.builder` = 懒加载：只渲染屏幕上可见的部分，离屏的自动销毁，节省内存。`.builder` 配合 ChatBubble 使用，确保大量消息不卡顿。

---

## 4. 布局容器层

### Row / Column — 水平/垂直排列

```dart
Row(children: [图标, 标题, 箭头])     // 从左到右
Column(children: [标题, 描述, 按钮])  // 从上到下
```

- `mainAxisAlignment`：主轴方向对齐（Row 是水平，Column 是垂直）
- `crossAxisAlignment`：交叉轴方向对齐

### Expanded — 占据剩余空间

```dart
Row(children: [
  Text('固定'),
  Expanded(child: Text('剩下的空间归我')),  // ← 撑满
  Icon(Icons.arrow),
])
```

类似聚餐分菜——固定宽度的先夹走，Expanded 说「剩下的我包了」。

### Padding — 内外间距

```dart
Padding(
  padding: EdgeInsets.all(16),                       // 四周
  // EdgeInsets.symmetric(horizontal: 20, vertical: 6) // 对称
  // EdgeInsets.only(left: 8)                          // 单边
  child: Text('hello'),
)
```

### SizedBox — 固定间隙

```dart
SizedBox(width: 8),   // 8px 横向间距
SizedBox(height: 12), // 12px 纵向间距
```

功能等价于 `<div style="width:8px">`。没有它，Row 里的元素会紧贴。

---

## 5. 样式容器层

### Container — 万能盒子

```dart
Container(
  width: 48,
  height: 48,
  padding: EdgeInsets.all(12),
  decoration: BoxDecoration(
    color: Colors.white,
    borderRadius: BorderRadius.circular(16),
    boxShadow: [...],
  ),
  child: Text('内容'),
)
```

一个 Container = HTML 的 `<div>` + CSS 的 `width/height/padding/background/border-radius/box-shadow`。

### Material + InkWell — 水波纹点击

```dart
Material(                         // ① 提供裁剪区域
  borderRadius: BorderRadius.circular(16),
  child: InkWell(                 // ② 提供水波纹
    onTap: () { ... },
    borderRadius: BorderRadius.circular(16),
    child: Padding(...),          // ③ 实际内容
  ),
)
```

**必须 Material + InkWell 配合使用**。单独的 InkWell 不会有水波纹。

### Center — 居中

```dart
Center(child: Text('我在正中间'))
```

---

## 6. 基础组件层

### Text — 文字

```dart
Text('职业发展', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600))
```

### TextField — 输入框

```dart
TextField(
  controller: _controller,              // TextEditingController
  onSubmitted: (_) => _handleSubmit(),  // 按回车触发
  decoration: InputDecoration(
    hintText: '输入你的回答...',
    border: OutlineInputBorder(...),
  ),
)
```

`TextEditingController` 是关键：`_controller.text` 读内容，`_controller.clear()` 清空。

### IconButton — 图标按钮

```dart
IconButton(icon: Icon(Icons.send_rounded), onPressed: _handleSubmit)
```

### CircleAvatar — 圆形头像

```dart
CircleAvatar(radius: 16, backgroundColor: AppTheme.primary, child: Text('AI'))
```

---

## 7. StatelessWidget vs StatefulWidget

| | StatelessWidget | StatefulWidget |
|:--|:--|:--|
| 内部有可变数据？ | 没有 | 有 |
| build() 何时执行？ | 参数变了就重建 | 调用 setState() 时重建 |
| 我们项目中的例子 | TopicCard / ChatBubble / ChatPage | ChatInput / ThinkingIndicator |
| 选择依据 | 成分只依赖构造参数 | 需要管理输入框、动画、计时器等 |

```dart
// Stateless：外观只取决于 topic 参数
class TopicCard extends StatelessWidget {
  final TopicItem topic;
  // 没有内部变量会自己变化
}

// Stateful：_controller.text 在用户打字时不断变化
class _ChatInputState extends State<ChatInput> {
  final _controller = TextEditingController();  // ← 内部可变状态
}
```

**原则：默认用 Stateless，只在必要时才升级为 Stateful。**

---

## 8. 与 HTML/CSS 的对照表

| HTML + CSS | Flutter |
|:--|:--|
| `<div>` | `Container` / `SizedBox` |
| `display: flex; flex-direction: row` | `Row()` |
| `display: flex; flex-direction: column` | `Column()` |
| `flex: 1` | `Expanded()` |
| `padding: 16px` | `Padding(padding: EdgeInsets.all(16))` |
| `border-radius: 16px` | `BorderRadius.circular(16)` |
| `box-shadow` | `BoxShadow(...)` |
| `background-color` | `BoxDecoration(color: ...)` |
| `<input>` | `TextField` |
| `onclick` | `onTap` / `onPressed` |
| `text-align: center` | `Center()` / `textAlign: TextAlign.center` |
| **不存在于 HTML** | `Material`（裁剪+墨水效果）、`Scaffold`（页面骨架）|
