class AppConstants {
  static const String appName = 'Socratic AI';
  static const String appTagline = '帮你想清楚';

  static const List<TopicItem> presetTopics = [
    TopicItem(
      icon: '🧭',
      title: '职业发展',
      description: '该深耕还是该转型？',
    ),
    TopicItem(
      icon: '💭',
      title: '两难决策',
      description: '两个选项，怎么选？',
    ),
    TopicItem(
      icon: '🧠',
      title: '自我探索',
      description: '我想成为什么样的人？',
    ),
    TopicItem(
      icon: '💼',
      title: '工作难题',
      description: '这个问题到底卡在哪？',
    ),
    TopicItem(
      icon: '❤️',
      title: '人际关系',
      description: '这段关系我该怎么看？',
    ),
  ];
}

class TopicItem {
  final String icon;
  final String title;
  final String description;

  const TopicItem({
    required this.icon,
    required this.title,
    required this.description,
  });
}
