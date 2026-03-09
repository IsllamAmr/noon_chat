import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/widgets.dart';

class SessionPresence extends StatefulWidget {
  final Widget child;
  const SessionPresence({super.key, required this.child});

  @override
  State<SessionPresence> createState() => _SessionPresenceState();
}

class _SessionPresenceState extends State<SessionPresence>
    with WidgetsBindingObserver {
  static const Duration _minPresenceWriteGap = Duration(seconds: 10);
  DateTime _lastPresenceWriteAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool? _lastOnline;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _setOnline(true);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _setOnline(false);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _setOnline(true);
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.inactive) {
      _setOnline(false);
    }
  }

  Future<void> _setOnline(bool value) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    final now = DateTime.now();
    if (_lastOnline == value &&
        now.difference(_lastPresenceWriteAt) < _minPresenceWriteGap) {
      return;
    }
    _lastOnline = value;
    _lastPresenceWriteAt = now;
    try {
      await FirebaseFirestore.instance.collection('users').doc(uid).set({
        'online': value,
        'lastSeen': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint('Presence update failed for $uid: $e');
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
