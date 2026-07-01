import 'package:flutter/foundation.dart';

class TopicProvider extends ChangeNotifier {
  String? _selectedTopic;
  String _customTopic = '';

  String? get selectedTopic => _selectedTopic;
  String get customTopic => _customTopic;

  void selectTopic(String topic) {
    _selectedTopic = topic;
    notifyListeners();
  }

  void setCustomTopic(String topic) {
    _customTopic = topic;
    _selectedTopic = null;
    notifyListeners();
  }

  void reset() {
    _selectedTopic = null;
    _customTopic = '';
    notifyListeners();
  }
}
