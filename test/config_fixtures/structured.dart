import 'package:grumpy_annotations/grumpy_annotations.dart';

class RetryPolicy {
  const RetryPolicy({this.attempts = 3});
  final int attempts;
}

@config
class GlobalSettings {
  const GlobalSettings({
    this.retry = const RetryPolicy(),
    this.weights = const {'first': 1.0},
  });
  final RetryPolicy retry;
  final Map<String, double> weights;
}
