import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'screens/room_screen.dart';
import 'services/auth_service.dart';
import 'services/webrtc_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // In Flutter Web, we try initializing Firebase. If configurations are missing, it falls back gracefully to Mock mode.
  // Note: Standard firebase_core packages throw exceptions if project setup hasn't been done.
  // We wrap this in a try-catch to enable instant local developer testing.
  dynamic firebaseAuth;
  dynamic firebaseFirestore;

  try {
    // Attempt standard web initialization if config values exist
    // For local PoC dev bypass, we do not require these parameters.
    // await Firebase.initializeApp();
  } catch (e) {
    debugPrint("Firebase could not be initialized: $e. Falling back to Mock mode.");
  }

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(
          create: (_) => AuthService(
            auth: firebaseAuth,
            firestore: firebaseFirestore,
          ),
        ),
        ChangeNotifierProvider(
          create: (_) => WebRTCService(),
        ),
      ],
      child: const MyApp(),
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Guitar EAD Chat',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0F0E17),
        primarySwatch: Colors.deepPurple,
      ),
      home: const MainGate(),
    );
  }
}

class MainGate extends StatelessWidget {
  const MainGate({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = Provider.of<AuthService>(context);
    if (auth.isAuthenticated) {
      return const RoomScreen();
    }
    return const LoginScreen();
  }
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailController = TextEditingController(text: 'musician1@ead.com');
  final _passwordController = TextEditingController(text: 'secret123');
  final _nameController = TextEditingController(text: 'Hendrix');
  bool _isSignUp = false;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final auth = Provider.of<AuthService>(context);

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF0F0E17), Color(0xFF1B112B)],
          ),
        ),
        child: Center(
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Container(
                constraints: const BoxConstraints(maxWidth: 400),
                padding: const EdgeInsets.all(32),
                decoration: BoxDecoration(
                  color: const Color(0xFF15141F).withOpacity(0.85),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: const Color(0xFF262438), width: 1.5),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.5),
                      blurRadius: 30,
                      offset: const Offset(0, 10),
                    )
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Connection Mode Status Badge
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          "GUITAR EAD CHAT",
                          style: TextStyle(
                            color: Color(0xFFD53F8C),
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 1.5,
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: auth.isMockMode
                                ? const Color(0xFFD97706).withOpacity(0.15)
                                : const Color(0xFF10B981).withOpacity(0.15),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: auth.isMockMode
                                  ? const Color(0xFFD97706).withOpacity(0.4)
                                  : const Color(0xFF10B981).withOpacity(0.4),
                            ),
                          ),
                          child: Text(
                            auth.isMockMode ? "LOCAL DEV MODE" : "FIREBASE: SP",
                            style: TextStyle(
                              color: auth.isMockMode ? const Color(0xFFFBBF24) : const Color(0xFF34D399),
                              fontSize: 9,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),

                    // Welcome Text
                    Text(
                      _isSignUp ? "Create Account" : "Welcome Back",
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 28,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _isSignUp ? "Sign up to start sharing high-quality raw audio" : "Log in to join your session",
                      style: const TextStyle(color: Colors.white60, fontSize: 13),
                    ),
                    const SizedBox(height: 32),

                    // Register name field if signing up
                    if (_isSignUp) ...[
                      const Text("DISPLAY NAME", style: TextStyle(color: Colors.white38, fontSize: 10, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 6),
                      TextField(
                        controller: _nameController,
                        style: const TextStyle(color: Colors.white),
                        decoration: _inputDecoration(Icons.person),
                      ),
                      const SizedBox(height: 16),
                    ],

                    // Email Input
                    const Text("EMAIL ADDRESS", style: TextStyle(color: Colors.white38, fontSize: 10, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 6),
                    TextField(
                      controller: _emailController,
                      style: const TextStyle(color: Colors.white),
                      decoration: _inputDecoration(Icons.email),
                    ),
                    const SizedBox(height: 16),

                    // Password Input
                    const Text("PASSWORD", style: TextStyle(color: Colors.white38, fontSize: 10, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 6),
                    TextField(
                      controller: _passwordController,
                      obscureText: true,
                      style: const TextStyle(color: Colors.white),
                      decoration: _inputDecoration(Icons.lock),
                    ),
                    const SizedBox(height: 32),

                    // Login Button
                    SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF8B5CF6),
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          elevation: 0,
                        ),
                        onPressed: auth.isLoading
                            ? null
                            : () async {
                                final success = await auth.signIn(
                                  _emailController.text.trim(),
                                  _passwordController.text.trim(),
                                  displayName: _isSignUp ? _nameController.text.trim() : null,
                                );
                                if (!success && mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(content: Text("Authentication Failed. Check logs.")),
                                  );
                                }
                              },
                        child: auth.isLoading
                            ? const SizedBox(
                                width: 24,
                                height: 24,
                                child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5),
                              )
                            : Text(
                                _isSignUp ? "SIGN UP" : "SIGN IN",
                                style: const TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.2),
                              ),
                      ),
                    ),
                    const SizedBox(height: 20),

                    // Mode Toggle Action
                    Center(
                      child: TextButton(
                        onPressed: () {
                          setState(() {
                            _isSignUp = !_isSignUp;
                          });
                        },
                        child: Text(
                          _isSignUp ? "Already have an account? Sign In" : "Don't have an account? Sign Up",
                          style: const TextStyle(color: Color(0xFFC4B5FD)),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  InputDecoration _inputDecoration(IconData icon) {
    return InputDecoration(
      prefixIcon: Icon(icon, color: const Color(0xFF8B5CF6).withOpacity(0.6)),
      filled: true,
      fillColor: const Color(0xFF1E1C2E),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFF8B5CF6), width: 1.5),
      ),
      contentPadding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
    );
  }
}
