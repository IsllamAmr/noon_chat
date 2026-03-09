import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noon_chat/user_service.dart';

void main() {
  group('PeopleSearchRepository (fake Firestore)', () {
    test('searches users by prefix on nameLower', () async {
      final db = FakeFirebaseFirestore();
      final repo = PeopleSearchRepository(db);

      await db.collection('users').doc('u1').set({
        'name': 'Ali',
        'nameLower': 'ali',
      });
      await db.collection('users').doc('u2').set({
        'name': 'Alice',
        'nameLower': 'alice',
      });
      await db.collection('users').doc('u3').set({
        'name': 'Mona',
        'nameLower': 'mona',
      });

      final snap = await repo.queryByName('ali').get();
      final ids = snap.docs.map((d) => d.id).toList();

      expect(ids, contains('u1'));
      expect(ids, contains('u2'));
      expect(ids, isNot(contains('u3')));
    });

    test('empty query returns sorted users with limit', () async {
      final db = FakeFirebaseFirestore();
      final repo = PeopleSearchRepository(db);

      await db.collection('users').doc('u1').set({'nameLower': 'charlie'});
      await db.collection('users').doc('u2').set({'nameLower': 'bravo'});
      await db.collection('users').doc('u3').set({'nameLower': 'alpha'});

      final snap = await repo.queryByName('', limit: 2).get();
      final values = snap.docs.map((d) => d.data()['nameLower']).toList();

      expect(values.length, 2);
      expect(values.first, 'alpha');
      expect(values.last, 'bravo');
    });
  });
}
