import 'package:flutter_test/flutter_test.dart';
import 'package:client/services/auth_service.dart';

void main() {
  test('UserProfile properties and toMap serialization', () {
    final user = UserProfile(
      uid: 'musician123',
      displayName: 'Jimi Hendrix',
      email: 'jimi@ead.com',
    );

    expect(user.uid, 'musician123');
    expect(user.displayName, 'Jimi Hendrix');
    expect(user.email, 'jimi@ead.com');

    final map = user.toMap();
    expect(map['uid'], 'musician123');
    expect(map['displayName'], 'Jimi Hendrix');
    expect(map['email'], 'jimi@ead.com');
  });
}
