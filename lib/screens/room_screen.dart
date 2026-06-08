import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:provider/provider.dart';
import '../services/auth_service.dart';
import '../services/webrtc_service.dart';

class RoomScreen extends StatefulWidget {
  const RoomScreen({super.key});

  @override
  State<RoomScreen> createState() => _RoomScreenState();
}

class _RoomScreenState extends State<RoomScreen> with TickerProviderStateMixin {
  final _roomController = TextEditingController(text: 'musicians-lounge');
  final _usernameController = TextEditingController();
  final _wsUrlController = TextEditingController(text: 'ws://localhost:8080/ws');
  final _invitesController = TextEditingController(); // Comma-separated emails

  late AnimationController _pulseController;
  StreamSubscription<DocumentSnapshot>? _roomSubscription;

  // Pre-join Call Configuration
  String _selectedCallType = 'sfu'; // 'p2p' or 'sfu'
  int _maxParticipants = 4;
  int _timeLimitMinutes = 40;

  // Lobby States
  bool _isWaitingForApproval = false;
  bool _isRejected = false;
  bool _isConnecting = false;

  // Firestore room data cached locally
  Map<String, dynamic>? _firestoreRoomData;

  // Remaining Session Duration
  Timer? _sessionCountdownTimer;
  int _secondsRemaining = 0;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);

    // Deep Linking parser: check for room query parameter
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final urlRoom = Uri.base.queryParameters['room'];
      if (urlRoom != null && urlRoom.isNotEmpty) {
        _roomController.text = urlRoom;
      }
      // Load audio hardware list
      Provider.of<WebRTCService>(context, listen: false).loadAudioDevices();
    });
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _roomController.dispose();
    _usernameController.dispose();
    _wsUrlController.dispose();
    _invitesController.dispose();
    _roomSubscription?.cancel();
    _sessionCountdownTimer?.cancel();
    super.dispose();
  }

  // Lobby & Connection Logic
  Future<void> _handleJoinCall(AuthService auth, WebRTCService webrtc) async {
    final roomId = _roomController.text.trim();
    final username = _usernameController.text.trim();
    final wsUrl = _wsUrlController.text.trim();
    final token = await auth.getIdToken();

    if (roomId.isEmpty || username.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Please fill in Room and Display Name.")),
      );
      return;
    }

    setState(() {
      _isConnecting = true;
      _isRejected = false;
    });

    if (auth.isMockMode) {
      // Mock bypass: connect directly to WebSocket
      await webrtc.connect(
        wsUrl,
        roomId,
        token,
        username,
        callType: _selectedCallType,
        maxParticipants: _maxParticipants,
        timeLimitMinutes: _timeLimitMinutes,
      );
      _startSessionCountdown(_timeLimitMinutes * 60);
      setState(() {
        _isConnecting = false;
      });
      return;
    }

    // Live Firebase Lobby / Access controls
    try {
      final firestore = FirebaseFirestore.instance;
      final roomRef = firestore.collection('rooms').doc(roomId);
      final roomSnap = await roomRef.get();

      final myUid = auth.currentUser!.uid;
      final myEmail = auth.currentUser!.email;

      if (!roomSnap.exists) {
        // 1. Current user is Host. Create the room document.
        final List<String> invitedList = _invitesController.text
            .split(',')
            .map((e) => e.trim().toLowerCase())
            .where((e) => e.isNotEmpty)
            .toList();

        await roomRef.set({
          'roomId': roomId,
          'name': roomId,
          'hostId': myUid,
          'callType': _selectedCallType,
          'invitedEmails': invitedList,
          'allowedUserIds': [myUid],
          'pendingRequests': [],
          'maxParticipants': _selectedCallType == 'p2p' ? 2 : _maxParticipants,
          'timeLimitMinutes': _selectedCallType == 'p2p' ? 120 : _timeLimitMinutes,
          'createdAt': FieldValue.serverTimestamp(),
        });

        // Host connects immediately
        await _connectWebSocketSignaling(webrtc, wsUrl, roomId, token, username, _selectedCallType);
      } else {
        // 2. Current user is a Guest.
        final data = roomSnap.data()!;
        _selectedCallType = data['callType'] ?? 'sfu';
        final hostId = data['hostId'];
        final invitedEmails = List<String>.from(data['invitedEmails'] ?? []);
        final allowedUserIds = List<String>.from(data['allowedUserIds'] ?? []);

        if (myUid == hostId ||
            allowedUserIds.contains(myUid) ||
            invitedEmails.contains(myEmail.toLowerCase())) {
          // Invited or already allowed -> Add to allowed if not there, and connect
          if (!allowedUserIds.contains(myUid)) {
            await roomRef.update({
              'allowedUserIds': FieldValue.arrayUnion([myUid])
            });
          }
          await _connectWebSocketSignaling(webrtc, wsUrl, roomId, token, username, _selectedCallType);
        } else {
          // Not invited -> Enter Lobby
          setState(() {
            _isWaitingForApproval = true;
          });

          // Write join request to pendingRequests
          await roomRef.update({
            'pendingRequests': FieldValue.arrayUnion([
              {
                'uid': myUid,
                'displayName': username,
                'email': myEmail,
              }
            ])
          });

          // Listen to room updates
          _roomSubscription = roomRef.snapshots().listen((snap) async {
            if (!snap.exists) return;
            final updatedData = snap.data()!;
            final updatedAllowed = List<String>.from(updatedData['allowedUserIds'] ?? []);
            final updatedPending = List<dynamic>.from(updatedData['pendingRequests'] ?? []);

            // Check if allowed
            if (updatedAllowed.contains(myUid)) {
              _roomSubscription?.cancel();
              setState(() {
                _isWaitingForApproval = false;
                _isConnecting = false;
              });
              await _connectWebSocketSignaling(webrtc, wsUrl, roomId, token, username, _selectedCallType);
            } else {
              // Check if rejected (removed from pending but not in allowed)
              final stillPending = updatedPending.any((req) => req['uid'] == myUid);
              if (!stillPending && !updatedAllowed.contains(myUid)) {
                _roomSubscription?.cancel();
                setState(() {
                  _isWaitingForApproval = false;
                  _isRejected = true;
                  _isConnecting = false;
                });
              }
            }
          });
        }
      }

      // Keep snapshot listener for the Host/Guests to handle pending lists
      _listenToRoomState(roomId);
    } catch (e) {
      debugPrint("Lobby configuration failed: $e");
      setState(() {
        _isConnecting = false;
        _isWaitingForApproval = false;
      });
    }
  }

  // Connects WebSocket once Lobby check clears
  Future<void> _connectWebSocketSignaling(
    WebRTCService webrtc,
    String wsUrl,
    String roomId,
    String token,
    String username,
    String callType,
  ) async {
    await webrtc.connect(
      wsUrl,
      roomId,
      token,
      username,
      callType: callType,
      maxParticipants: _maxParticipants,
      timeLimitMinutes: _timeLimitMinutes,
    );
    _startSessionCountdown(_timeLimitMinutes * 60);
    setState(() {
      _isConnecting = false;
    });
  }

  // Listen to Room snapshot for Lobby dashboard (Host list requests)
  void _listenToRoomState(String roomId) {
    _roomSubscription?.cancel();
    _roomSubscription = FirebaseFirestore.instance
        .collection('rooms')
        .doc(roomId)
        .snapshots()
        .listen((snap) {
      if (snap.exists && mounted) {
        setState(() {
          _firestoreRoomData = snap.data();
        });
      }
    });
  }

  // Host Action: Accept Entry request
  Future<void> _acceptParticipant(String uid, String displayName, String email) async {
    if (_firestoreRoomData == null) return;
    final roomId = _firestoreRoomData!['roomId'];
    final roomRef = FirebaseFirestore.instance.collection('rooms').doc(roomId);

    await FirebaseFirestore.instance.runTransaction((transaction) async {
      transaction.update(roomRef, {
        'allowedUserIds': FieldValue.arrayUnion([uid]),
        'pendingRequests': FieldValue.arrayRemove([
          {
            'uid': uid,
            'displayName': displayName,
            'email': email,
          }
        ]),
      });
    });
  }

  // Host Action: Deny Entry request
  Future<void> _denyParticipant(String uid, String displayName, String email) async {
    if (_firestoreRoomData == null) return;
    final roomId = _firestoreRoomData!['roomId'];
    final roomRef = FirebaseFirestore.instance.collection('rooms').doc(roomId);

    await roomRef.update({
      'pendingRequests': FieldValue.arrayRemove([
        {
          'uid': uid,
          'displayName': displayName,
          'email': email,
        }
      ]),
    });
  }

  // Start Call Countdown Timer
  void _startSessionCountdown(int seconds) {
    _sessionCountdownTimer?.cancel();
    _secondsRemaining = seconds;
    _sessionCountdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_secondsRemaining <= 0) {
        _sessionCountdownTimer?.cancel();
      } else {
        if (mounted) {
          setState(() {
            _secondsRemaining--;
          });
        }
      }
    });
  }

  String _formatDuration(int totalSeconds) {
    final int minutes = totalSeconds ~/ 60;
    final int seconds = totalSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final authService = Provider.of<AuthService>(context);
    final webrtcService = Provider.of<WebRTCService>(context);

    if (_usernameController.text.isEmpty && authService.currentUser != null) {
      _usernameController.text = authService.currentUser!.displayName;
    }

    return Scaffold(
      backgroundColor: const Color(0xFF0F0E17),
      appBar: _buildAppBar(authService, webrtcService),
      body: _buildMainBody(authService, webrtcService),
    );
  }

  // App Bar
  AppBar _buildAppBar(AuthService auth, WebRTCService webrtc) {
    return AppBar(
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
        if (auth.isAuthenticated)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: PopupMenuButton<String>(
              offset: const Offset(0, 50),
              color: const Color(0xFF1E1C2E),
              onSelected: (value) async {
                if (value == 'logout') {
                  _roomSubscription?.cancel();
                  await webrtc.leave();
                  await auth.signOut();
                } else if (value == 'delete_account') {
                  final confirm = await _showDeleteAccountConfirmation();
                  if (confirm == true) {
                    _roomSubscription?.cancel();
                    await webrtc.leave();
                    final deleted = await auth.deleteAccount();
                    if (deleted && mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text("Account completely erased under LGPD.")),
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
                    auth.currentUser!.displayName.substring(0, 1).toUpperCase(),
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
                label: Text(
                  auth.currentUser!.displayName,
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
    );
  }

  Future<bool?> _showDeleteAccountConfirmation() {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1829),
        title: const Text("Delete Account (LGPD)", style: TextStyle(color: Colors.white)),
        content: const Text(
          "Under LGPD Article 18, this action will permanently erase your auth profile and Firestore files. This is irreversible. Do you want to proceed?",
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
  }

  // Switch display between Lobby, Connect Setup, and Call View
  Widget _buildMainBody(AuthService auth, WebRTCService webrtc) {
    if (webrtc.isJoined) {
      return _buildActiveRoomView(context, webrtc, auth);
    }
    if (_isWaitingForApproval) {
      return _buildLobbyWaitingView();
    }
    return _buildJoinRoomView(context, webrtc, auth);
  }

  // Lobby Waiting Screen
  Widget _buildLobbyWaitingView() {
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 400),
        padding: const EdgeInsets.all(32),
        decoration: BoxDecoration(
          color: const Color(0xFF15141F),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: const Color(0xFF262438)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: Color(0xFF8B5CF6)),
            const SizedBox(height: 24),
            const Text(
              "Waiting for Host...",
              style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            const Text(
              "You are in the waiting list. The host has been notified to approve your entry request.",
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white60, fontSize: 13),
            ),
            const SizedBox(height: 24),
            TextButton(
              onPressed: () {
                _roomSubscription?.cancel();
                setState(() {
                  _isWaitingForApproval = false;
                  _isConnecting = false;
                });
              },
              child: const Text("Cancel Join Request", style: TextStyle(color: Colors.redAccent)),
            ),
          ],
        ),
      ),
    );
  }

  // Active call interface
  Widget _buildActiveRoomView(BuildContext context, WebRTCService service, AuthService auth) {
    final bool isHost = _firestoreRoomData != null && _firestoreRoomData!['hostId'] == auth.currentUser?.uid;
    final pendingRequests = List<dynamic>.from(_firestoreRoomData?['pendingRequests'] ?? []);

    return Row(
      children: [
        // Left Side: Main Call Views
        Expanded(
          flex: 3,
          child: Column(
            children: [
              // Top session details
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
                              ),
                            );
                          },
                        ),
                        const SizedBox(width: 8),
                        Text(
                          "Room: ${service.roomId} (${service.callType?.toUpperCase()})",
                          style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                    if (service.callType == 'sfu' && _secondsRemaining > 0)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: const Color(0xFFEF4444).withOpacity(0.15),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: const Color(0xFFEF4444).withOpacity(0.3)),
                        ),
                        child: Text(
                          "Time Remaining: ${_formatDuration(_secondsRemaining)}",
                          style: const TextStyle(color: Color(0xFFFCA5A5), fontSize: 11, fontWeight: FontWeight.bold),
                        ),
                      ),
                  ],
                ),
              ),

              // Render Grid of Participant Videos
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: GridView.builder(
                    itemCount: service.remoteParticipants.length + 1, // +1 for local
                    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 320,
                      crossAxisSpacing: 16,
                      mainAxisSpacing: 16,
                      childAspectRatio: 1.2,
                    ),
                    itemBuilder: (context, index) {
                      if (index == 0) {
                        // Local View
                        return _buildLocalParticipantVideo(service);
                      }

                      // Remote View
                      final p = service.remoteParticipants[index - 1];
                      return _buildRemoteParticipantVideo(service, p);
                    },
                  ),
                ),
              ),

              // Control Panel
              _buildCallControls(service),
            ],
          ),
        ),

        // Right Side: Host Lobby Drawer (visible only to Host when pending requests exist)
        if (isHost && pendingRequests.isNotEmpty)
          Container(
            width: 280,
            decoration: const BoxDecoration(
              color: Color(0xFF15141F),
              border: Border(left: BorderSide(color: Color(0xFF262438), width: 1)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.all(16.0),
                  child: Text(
                    "Waiting Lobby",
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                ),
                const Divider(color: Color(0xFF262438)),
                Expanded(
                  child: ListView.builder(
                    itemCount: pendingRequests.length,
                    itemBuilder: (context, index) {
                      final req = pendingRequests[index];
                      final uid = req['uid'];
                      final name = req['displayName'];
                      final email = req['email'];

                      return ListTile(
                        title: Text(name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                        subtitle: Text(email, style: const TextStyle(color: Colors.white54, fontSize: 11)),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.check_circle, color: Color(0xFF10B981)),
                              onPressed: () => _acceptParticipant(uid, name, email),
                            ),
                            IconButton(
                              icon: const Icon(Icons.cancel, color: Color(0xFFEF4444)),
                              onPressed: () => _denyParticipant(uid, name, email),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          )
      ],
    );
  }

  // Local Video Card
  Widget _buildLocalParticipantVideo(WebRTCService service) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1E1C2E),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF8B5CF6).withOpacity(0.5), width: 2),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Stack(
          children: [
            service.isCameraOn && service.localRenderer != null
                ? RTCVideoView(service.localRenderer!, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover)
                : Container(
                    color: const Color(0xFF1A1829),
                    child: const Center(
                      child: Icon(Icons.videocam_off, color: Colors.white38, size: 48),
                    ),
                  ),
            // Info tag overlay
            Positioned(
              bottom: 12,
              left: 12,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.6),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  "You ${service.isMuted ? '(Muted)' : ''}",
                  style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Remote Video Card (with individual volume controls)
  Widget _buildRemoteParticipantVideo(WebRTCService service, RemoteParticipant p) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1E1C2E),
        borderRadius: BorderRadius.circular(16),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Stack(
          children: [
            RTCVideoView(p.renderer, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover),
            
            // Info overlay with Volume Slider
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                color: Colors.black.withOpacity(0.6),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        p.username,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                      ),
                    ),
                    Row(
                      children: [
                        const Icon(Icons.volume_up, color: Colors.white70, size: 14),
                        SizedBox(
                          width: 80,
                          height: 20,
                          child: Slider(
                            value: p.volume,
                            min: 0.0,
                            max: 1.0,
                            activeColor: const Color(0xFF8B5CF6),
                            onChanged: (val) {
                              service.setParticipantVolume(p.userId, val);
                            },
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Call dashboard controls
  Widget _buildCallControls(WebRTCService service) {
    return Container(
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
          // Audio Device Selector Dropdown
          if (service.audioDevices.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: const Color(0xFF262438),
                borderRadius: BorderRadius.circular(8),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  dropdownColor: const Color(0xFF1E1C2E),
                  value: service.selectedAudioInputId,
                  icon: const Icon(Icons.keyboard_arrow_down, color: Colors.white70),
                  onChanged: (String? newId) {
                    if (newId != null) {
                      service.setAudioInputDevice(newId);
                    }
                  },
                  items: service.audioDevices.map<DropdownMenuItem<String>>((device) {
                    return DropdownMenuItem<String>(
                      value: device.deviceId,
                      child: Text(
                        device.label.isNotEmpty ? device.label : "Audio Channel ${device.deviceId.substring(0, 4)}",
                        style: const TextStyle(color: Colors.white, fontSize: 12),
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),
          const SizedBox(width: 20),

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
          const SizedBox(width: 12),

          // Camera Toggle Button
          IconButton(
            iconSize: 32,
            icon: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: !service.isCameraOn ? const Color(0xFFEF4444) : const Color(0xFF262438),
                shape: BoxShape.circle,
              ),
              child: Icon(
                service.isCameraOn ? Icons.videocam : Icons.videocam_off,
                color: Colors.white,
              ),
            ),
            onPressed: () => service.toggleCamera(),
          ),
          const SizedBox(width: 20),

          // Leave Call Button
          IconButton(
            iconSize: 32,
            icon: Container(
              padding: const EdgeInsets.all(12),
              decoration: const BoxDecoration(
                color: Color(0xFFEF4444),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.call_end, color: Colors.white),
            ),
            onPressed: () {
              _roomSubscription?.cancel();
              service.leave();
            },
          ),
        ],
      ),
    );
  }

  // Pre-join form screen
  Widget _buildJoinRoomView(BuildContext context, WebRTCService webrtcService, AuthService authService) {
    return Center(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 440),
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
                // Error state indicator
                if (_isRejected)
                  Container(
                    margin: const EdgeInsets.only(bottom: 20),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEF4444).withOpacity(0.15),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFFEF4444).withOpacity(0.4)),
                    ),
                    child: const Text(
                      "Your request to join this session was denied by the host.",
                      style: TextStyle(color: Color(0xFFFCA5A5), fontSize: 13),
                    ),
                  ),

                const Text(
                  "Join Session",
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 24),
                ),
                const SizedBox(height: 6),
                const Text(
                  "Configure call parameters, invitation list, and connect",
                  style: TextStyle(color: Colors.white60, fontSize: 13),
                ),
                const SizedBox(height: 24),

                // Room Input
                const Text("ROOM NAME / CALL ID", style: TextStyle(color: Colors.white38, fontSize: 10, fontWeight: FontWeight.bold)),
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
                const SizedBox(height: 20),

                // Call Type Selector
                const Text("CALL ROUTING TYPE", style: TextStyle(color: Colors.white38, fontSize: 10, fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: _buildTypeRadioButton(
                        title: "1:1 P2P",
                        value: "p2p",
                        groupValue: _selectedCallType,
                        onChanged: (val) {
                          setState(() {
                            _selectedCallType = val!;
                          });
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _buildTypeRadioButton(
                        title: "Group SFU",
                        value: "sfu",
                        groupValue: _selectedCallType,
                        onChanged: (val) {
                          setState(() {
                            _selectedCallType = val!;
                          });
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),

                // Config bounds visible if group SFU is active
                if (_selectedCallType == 'sfu') ...[
                  // Participant Cap & Duration limit indicator
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text("MAX PARTICIPANTS", style: TextStyle(color: Colors.white38, fontSize: 9, fontWeight: FontWeight.bold)),
                            const SizedBox(height: 4),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12),
                              decoration: BoxDecoration(
                                color: const Color(0xFF1E1C2E),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: DropdownButton<int>(
                                dropdownColor: const Color(0xFF1E1C2E),
                                value: _maxParticipants,
                                items: [2, 3, 4, 5].map((val) {
                                  return DropdownMenuItem<int>(
                                    value: val,
                                    child: Text("$val Users", style: const TextStyle(color: Colors.white, fontSize: 13)),
                                  );
                                }).toList(),
                                onChanged: (newVal) {
                                  if (newVal != null) {
                                    setState(() {
                                      _maxParticipants = newVal;
                                    });
                                  }
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text("TIME LIMIT (FREE TIER)", style: TextStyle(color: Colors.white38, fontSize: 9, fontWeight: FontWeight.bold)),
                            const SizedBox(height: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                              decoration: BoxDecoration(
                                color: const Color(0xFFEF4444).withOpacity(0.1),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: const Color(0xFFEF4444).withOpacity(0.3)),
                              ),
                              child: const Text(
                                "40 Mins Cap",
                                style: TextStyle(color: Color(0xFFFCA5A5), fontWeight: FontWeight.bold, fontSize: 12),
                              ),
                            ),
                          ],
                        ),
                      )
                    ],
                  ),
                  const SizedBox(height: 20),
                ],

                // Invited Emails (for lobby approvals bypass)
                if (!authService.isMockMode) ...[
                  const Text("INVITE EMAILS (OPTIONAL, COMMA-SEPARATED)", style: TextStyle(color: Colors.white38, fontSize: 10, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  TextField(
                    controller: _invitesController,
                    style: const TextStyle(color: Colors.white),
                    decoration: _inputDecoration(Icons.mail_outline),
                  ),
                  const SizedBox(height: 20),
                ],

                // WS Url (Hidden inside settings expander for cleaner UX)
                ExpansionTile(
                  title: const Text("Advanced Server Settings", style: TextStyle(color: Colors.white60, fontSize: 12)),
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 8, bottom: 16),
                      child: TextField(
                        controller: _wsUrlController,
                        style: const TextStyle(color: Colors.white),
                        decoration: _inputDecoration(Icons.settings_ethernet),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),

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
                    onPressed: _isConnecting
                        ? null
                        : () => _handleJoinCall(authService, webrtcService),
                    child: _isConnecting
                        ? const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5),
                          )
                        : const Text(
                            "CONNECT CALL",
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

  Widget _buildTypeRadioButton({
    required String title,
    required String value,
    required String groupValue,
    required ValueChanged<String?> onChanged,
  }) {
    final bool isSelected = value == groupValue;
    return GestureDetector(
      onTap: () => onChanged(value),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF8B5CF6).withOpacity(0.15) : const Color(0xFF1E1C2E),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? const Color(0xFF8B5CF6) : Colors.transparent,
            width: 1.5,
          ),
        ),
        child: Center(
          child: Text(
            title,
            style: TextStyle(
              color: isSelected ? Colors.white : Colors.white60,
              fontWeight: FontWeight.bold,
              fontSize: 13,
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
