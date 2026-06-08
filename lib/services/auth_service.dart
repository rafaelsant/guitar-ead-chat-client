import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

class UserProfile {
  final String uid;
  final String displayName;
  final String email;

  UserProfile({
    required this.uid,
    required this.displayName,
    required this.email,
  });

  Map<String, dynamic> toMap() {
    return {
      'uid': uid,
      'displayName': displayName,
      'email': email,
    };
  }
}

class AuthService extends ChangeNotifier {
  final FirebaseAuth? _auth;
  final FirebaseFirestore? _firestore;

  bool _isMockMode = false;
  UserProfile? _currentUser;
  bool _isLoading = false;

  AuthService({FirebaseAuth? auth, FirebaseFirestore? firestore})
      : _auth = auth,
        _firestore = firestore {
    if (_auth == null || _firestore == null) {
      _isMockMode = true;
      debugPrint("AuthService initialized in Mock Mode.");
    } else {
      // Listen to auth state changes
      _auth!.authStateChanges().listen(_onAuthStateChanged);
    }
  }

  bool get isMockMode => _isMockMode;
  UserProfile? get currentUser => _currentUser;
  bool get isLoading => _isLoading;
  bool get isAuthenticated => _currentUser != null;

  void setLoading(bool val) {
    _isLoading = val;
    notifyListeners();
  }

  Future<void> _onAuthStateChanged(User? firebaseUser) async {
    if (firebaseUser == null) {
      _currentUser = null;
      notifyListeners();
      return;
    }

    _currentUser = UserProfile(
      uid: firebaseUser.uid,
      displayName: firebaseUser.displayName ?? firebaseUser.email?.split('@').first ?? 'User',
      email: firebaseUser.email ?? '',
    );
    notifyListeners();
  }

  // Sign In / Register using Dev mode (Mock) or Firebase Auth
  Future<bool> signIn(String email, String password, {String? displayName}) async {
    setLoading(true);
    try {
      if (_isMockMode) {
        // Mock success
        final mockUid = email.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '');
        _currentUser = UserProfile(
          uid: mockUid,
          displayName: displayName ?? email.split('@').first,
          email: email,
        );
        setLoading(false);
        return true;
      }

      // Try signing in
      UserCredential cred;
      try {
        cred = await _auth!.signInWithEmailAndPassword(email: email, password: password);
      } on FirebaseAuthException catch (e) {
        if (e.code == 'user-not-found' || e.code == 'invalid-credential') {
          // Register
          cred = await _auth!.createUserWithEmailAndPassword(email: email, password: password);
          if (displayName != null) {
            await cred.user?.updateDisplayName(displayName);
          }
        } else {
          rethrow;
        }
      }

      final user = cred.user;
      if (user != null) {
        // Sync with Firestore (LGPD Data Minimization: uid, displayName, email)
        await _firestore!.collection('users').doc(user.uid).set({
          'uid': user.uid,
          'displayName': displayName ?? user.displayName ?? email.split('@').first,
          'email': email,
          'lastLogin': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      }
      setLoading(false);
      return true;
    } catch (e) {
      debugPrint("Sign in error: $e");
      setLoading(false);
      return false;
    }
  }

  // Get authentication token (for WebSocket header/query)
  Future<String> getIdToken() async {
    if (_isMockMode) {
      return "dev-token-${_currentUser?.uid ?? 'anonymous'}";
    }
    final user = _auth?.currentUser;
    if (user != null) {
      return await user.getIdToken() ?? '';
    }
    return '';
  }

  // Sign Out
  Future<void> signOut() async {
    if (_isMockMode) {
      _currentUser = null;
      notifyListeners();
      return;
    }
    await _auth!.signOut();
  }

  // LGPD right to erasure: delete user auth and firestore profile
  Future<bool> deleteAccount() async {
    if (_currentUser == null) return false;
    setLoading(true);
    try {
      final uid = _currentUser!.uid;

      if (_isMockMode) {
        _currentUser = null;
        setLoading(false);
        return true;
      }

      // 1. Delete Firestore User Document
      await _firestore!.collection('users').doc(uid).delete();

      // 2. Delete Auth User Record
      final user = _auth!.currentUser;
      if (user != null) {
        await user.delete();
      }

      _currentUser = null;
      setLoading(false);
      return true;
    } catch (e) {
      debugPrint("Error deleting account (LGPD Erasure): $e");
      setLoading(false);
      return false;
    }
  }
}
