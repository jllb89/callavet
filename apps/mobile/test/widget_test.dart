import 'package:flutter_test/flutter_test.dart';

import 'package:cav_mobile/src/app.dart';

void main() {
  test('mobile app shell is constructible', () {
    expect(const App(), isA<App>());
  });
}
