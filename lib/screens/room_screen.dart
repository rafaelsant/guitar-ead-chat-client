import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/auth_service.dart';
import '../services/webrtc_service.dart';

class RoomScreen extends StatefulWidget {
  const RoomScreen({super.key});

  @override
  State<RoomScreen> createState() => _RoomScreenState();
}

class _RoomScreenState extends State<RoomScreen> with SingleTickerProviderStateMixin {
  final _roomController = TextEditingController(text: 'musicians-lounge');
  final _usernameController = TextEditingController();
  final _wsUrlController = TextEditingController(text: 'ws://localhost:8080/ws');
  
  late AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _roomController.dispose();
    _usernameController.dispose();
    _wsUrlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final authService = Provider.of<AuthService>(context);
    final webrtcService = Provider.of<WebRTCService>(context);

    // Default username to displayName if not set
    if (_usernameController.text.isEmpty && authService.currentUser != null) {
      _usernameController.text = authService.currentUser!.displayName;
    }

    return Scaffold(
      backgroundColor: const Color(0xFF0F0E17), // Deep midnight black/violet
      appBar: AppBar(
        backgroundColor: const Color(0xFF15141F),
        elevation: 0,
        title: Row(
          children: [
            const Icon(Icons.audiotrack, color: Color(0xFFD53F8C)),
            const SizedBox(width: 8),
            Text(
              "Guitar EAD Chat",
              style: TextStyle(
                fontWeight: FontWeight.bold,
                foreground: Paint()
                  ..shader = const LinearGradient(
                    colors: [Color(0xFFEC4899), Color(0xFF8B5CF6)],
                  ).createShader(const Rect.fromLTWH(0.0, 0.0, 200.0, 70.0)),
              ),
            ),
          ],
        ),
        actions: [
          // LGPD and Profile Section
          if (authService.isAuthenticated)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: PopupMenuButton<String>(
                offset: const Offset(0, 50),
                color: const Color(0xFF1E1C2E),
                onSelected: (value) async {
                  if (value == 'logout') {
                    await webrtcService.leave();
                    await authService.signOut();
                  } else if (value == 'delete_account') {
                    // Show confirmation dialog for LGPD Account Erasure
                    final confirm = await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                        backgroundColor: const Color(0xFF1A1829),
                        title: const Text("Delete Account (LGPD)", style: TextStyle(color: Colors.white)),
                        content: const Text(
                          "Under LGPD Article 18, this action will permanently erase your authentication record and all linked Firestore files. This is irreversible. Do you want to proceed?",
                          style: TextStyle(color: Colors.white70),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.of(context).pop(false),
                            child: const Text("Cancel", style: TextStyle(color: Colors.grey)),
                          ),
                          ElevatedButton(
                            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
                            onPressed: () => Navigator.of(context).pop(true),
                            child: const Text("Permanently Erase"),
                          ),
                        ],
                      ),
                    );

                    if (confirm == true) {
                      await webrtcService.leave();
                      final deleted = await authService.deleteAccount();
                      if (deleted && mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text("Account and data completely erased under LGPD.")),
                        );
                      }
                    }
                  }
                },
                child: Chip(
                  backgroundColor: const Color(0xFF1E1C2F),
                  avatar: CircleAvatar(
                    backgroundColor: const Color(0xFF8B5CF6),
                    child: Text(
                      authService.currentUser!.displayName.substring(0, 1).toUpperCase(),
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ),
                  label: Text(
                    authService.currentUser!.displayName,
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
                itemBuilder: (context) => [
                  const PopupMenuItem<String>(
                    value: 'logout',
                    child: Row(
                      children: [
                        Icon(Icons.logout, color: Colors.white70, size: 18),
                        SizedBox(width: 8),
                        Text("Logout", style: TextStyle(color: Colors.white)),
                      ],
                    ),
                  ),
                  const PopupMenuItem<String>(
                    value: 'delete_account',
                    child: Row(
                      children: [
                        Icon(Icons.delete_forever, color: Colors.redAccent, size: 18),
                        SizedBox(width: 8),
                        Text("Delete Account", style: TextStyle(color: Colors.redAccent)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
      body: webrtcService.isJoined
          ? _buildActiveRoomView(context, webrtcService)
          : _buildJoinRoomView(context, webrtcService, authService),
    );
  }

  // Active call view
  Widget _buildActiveRoomView(BuildContext context, WebRTCService service) {
    return Column(
      children: [
        // Top status bar
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: const BoxDecoration(
            color: Color(0xFF15141F),
            border: Border(bottom: BorderSide(color: Color(0xFF262438), width: 1)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  AnimatedBuilder(
                    animation: _pulseController,
                    builder: (context, child) {
                      return Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: const Color(0xFF10B981).withOpacity(_pulseController.value * 0.5 + 0.5),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFF10B981).withOpacity(_pulseController.value * 0.4),
                              blurRadius: 8,
                              spreadRadius: 2,
                            )
                          ],
                        ),
                      );
                    },
                  ),
                  const SizedBox(width: 8),
                  Text(
                    "Connected to room: ${service.roomId}",
                    style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFF8B5CF6).withOpacity(0.15),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: const Color(0xFF8B5CF6).withOpacity(0.3)),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.surround_sound, color: Color(0xFF8B5CF6), size: 14),
                    SizedBox(width: 4),
                    Text(
                      "Raw 2-ch Stereo Audio Active",
                      style: TextStyle(color: Color(0xFFC4B5FD), fontSize: 11, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),

        // Participant Grid
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: GridView.builder(
              itemCount: service.remoteParticipants.length + 1, // +1 for local client
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 220,
                crossAxisSpacing: 16,
                mainAxisSpacing: 16,
                childAspectRatio: 1.1,
              ),
              itemBuilder: (context, index) {
                if (index == 0) {
                  // Local Participant card
                  return _buildParticipantCard(
                    context,
                    name: "You (${service.isMuted ? 'Muted' : 'Speaking'})",
                    isLocal: true,
                    isMuted: service.isMuted,
                  );
                }

                // Remote Participant card
                final participant = service.remoteParticipants[index - 1];
                return _buildParticipantCard(
                  context,
                  name: participant.username,
                  isLocal: false,
                  isMuted: false, // In simple PoC backend, mute updates aren't synchronized
                );
              },
            ),
          ),
        ),

        // Bottom control dashboard
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
          decoration: const BoxDecoration(
            color: Color(0xFF15141F),
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(24),
              topRight: Radius.circular(24),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Mute Button
              IconButton(
                iconSize: 32,
                icon: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: service.isMuted ? const Color(0xFFEF4444) : const Color(0xFF262438),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    service.isMuted ? Icons.mic_off : Icons.mic,
                    color: Colors.white,
                  ),
                ),
                onPressed: () => service.toggleMute(),
              ),
              const SizedBox(width: 20),

              // Disconnect Button
              IconButton(
                iconSize: 32,
                icon: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: const BoxDecoration(
                    color: Color(0xFFEF4444),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.call_end,
                    color: Colors.white,
                  ),
                ),
                onPressed: () => service.leave(),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // Card component for grids
  Widget _buildParticipantCard(
    BuildContext context, {
    required String name,
    required bool isLocal,
    required bool isMuted,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1E1C2E),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isLocal
              ? (isMuted ? Colors.redAccent.withOpacity(0.5) : const Color(0xFF8B5CF6).withOpacity(0.5))
              : Colors.transparent,
          width: 2,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.3),
            blurRadius: 8,
            offset: const Offset(0, 4),
          )
        ],
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Background graphic
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              height: 40,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [
                    (isMuted ? Colors.red : const Color(0xFF8B5CF6)).withOpacity(0.1),
                    Colors.transparent,
                  ],
                ),
                borderRadius: const BorderRadius.only(
                  bottomLeft: Radius.circular(16),
                  bottomRight: Radius.circular(16),
                ),
              ),
            ),
          ),

          // Central Profile Avatar
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircleAvatar(
                radius: 30,
                backgroundColor: isMuted ? const Color(0xFFEF4444).withOpacity(0.2) : const Color(0xFF8B5CF6).withOpacity(0.2),
                child: CircleAvatar(
                  radius: 24,
                  backgroundColor: isMuted ? const Color(0xFFEF4444) : const Color(0xFF8B5CF6),
                  child: Text(
                    name.substring(0, 1).toUpperCase(),
                    style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  name,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                ),
              ),
            ],
          ),

          // Small tag markers
          Positioned(
            top: 10,
            right: 10,
            child: isMuted
                ? const Icon(Icons.mic_off, color: Color(0xFFEF4444), size: 16)
                : const Icon(Icons.mic, color: Color(0xFF10B981), size: 16),
          ),

          if (isLocal)
            Positioned(
              top: 10,
              left: 10,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFF8B5CF6).withOpacity(0.3),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text(
                  "LOCAL",
                  style: TextStyle(color: Color(0xFFC4B5FD), fontSize: 8, fontWeight: FontWeight.bold),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // Pre-join/setup dashboard
  Widget _buildJoinRoomView(BuildContext context, WebRTCService webrtcService, AuthService authService) {
    return Center(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 420),
            padding: const EdgeInsets.all(32),
            decoration: BoxDecoration(
              color: const Color(0xFF15141F),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: const Color(0xFF262438), width: 1.5),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.4),
                  blurRadius: 24,
                  offset: const Offset(0, 12),
                )
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  "Join Session",
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 24,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  "Configure room, username, and connect",
                  style: TextStyle(color: Colors.white60, fontSize: 13),
                ),
                const SizedBox(height: 24),

                // Room Input
                const Text("ROOM NAME", style: TextStyle(color: Colors.white38, fontSize: 10, fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                TextField(
                  controller: _roomController,
                  style: const TextStyle(color: Colors.white),
                  decoration: _inputDecoration(Icons.meeting_room),
                ),
                const SizedBox(height: 16),

                // Username Input
                const Text("DISPLAY NAME", style: TextStyle(color: Colors.white38, fontSize: 10, fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                TextField(
                  controller: _usernameController,
                  style: const TextStyle(color: Colors.white),
                  decoration: _inputDecoration(Icons.person),
                ),
                const SizedBox(height: 16),

                // WebSocket server address
                const Text("SIGNALING WS SERVER URL", style: TextStyle(color: Colors.white38, fontSize: 10, fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                TextField(
                  controller: _wsUrlController,
                  style: const TextStyle(color: Colors.white),
                  decoration: _inputDecoration(Icons.settings_ethernet),
                ),
                const SizedBox(height: 32),

                // Join Button
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
                    onPressed: () async {
                      if (_roomController.text.trim().isEmpty || _usernameController.text.trim().isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text("Please fill in Room and Display Name.")),
                        );
                        return;
                      }

                      final token = await authService.getIdToken();
                      await webrtcService.connect(
                        _wsUrlController.text.trim(),
                        _roomController.text.trim(),
                        token,
                        _usernameController.text.trim(),
                      );
                    },
                    child: const Text(
                      "CONNECT AUDIO",
                      style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.2),
                    ),
                  ),
                ),
              ],
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
