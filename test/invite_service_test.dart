import 'package:flutter_test/flutter_test.dart';
import 'package:noon_chat/invite_service.dart';

void main() {
  group('InviteService link parsing', () {
    test('buildInviteLink + extract from path', () {
      final link = InviteService.buildInviteLink('ab23cd34');
      expect(InviteService.extractInviteId(link), equals('AB23CD34'));
    });

    test('extract from query parameter', () {
      final id = InviteService.extractInviteId(
        'https://noon-8531a.web.app/join?invite=KLMN2345',
      );
      expect(id, equals('KLMN2345'));
    });

    test('extract from app scheme link', () {
      final id = InviteService.extractInviteId('noonchat://invite/ZXCV2345');
      expect(id, equals('ZXCV2345'));
    });

    test('extract from share text containing a link', () {
      final id = InviteService.extractInviteId(
        'Noon Chat invite\nhttps://noon-8531a.web.app/invite/LMNO6789',
      );
      expect(id, equals('LMNO6789'));
    });

    test('extract from link with trailing punctuation', () {
      final id = InviteService.extractInviteId(
        'https://noon-8531a.web.app/invite/QWER2345).',
      );
      expect(id, equals('QWER2345'));
    });

    test('extract code-only input for backward compatibility', () {
      final id = InviteService.extractInviteId('pqrs6789');
      expect(id, equals('PQRS6789'));
    });

    test('invalid link returns null', () {
      final id = InviteService.extractInviteId('not-a-valid-link');
      expect(id, isNull);
    });
  });
}
