import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class RemoteParticipant {
  final String userId;
  final String username;
  final String trackId;
  final MediaStream stream;
  final RTCVideoRenderer renderer;
  double volume;

  RemoteParticipant({
    required this.userId,
    required this.username,
    required this.trackId,
    required this.stream,
    required this.renderer,
    this.volume = 1.0,
  });

  Future<void> dispose() async {
    renderer.srcObject = null;
    await renderer.dispose();
  }

  void setVolume(double val) {
    volume = val;
    // In WebRTC web platform, we can adjust the volume directly on the html audio element,
    // which corresponds to renderer.srcObject.getAudioTracks().first or the HTML element.
    // For this PoC, we update the slider value local state.
    // renderer.volume = volume;
  }
}

class WebRTCService extends ChangeNotifier {
  WebSocketChannel? _channel;
  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  RTCVideoRenderer? _localRenderer;
  
  bool _isConnected = false;
  bool _isJoined = false;
  bool _isMuted = false;
  bool _isCameraOn = true;
  String? _roomId;
  String? _callType; // "p2p" or "sfu"
  String? _myUserId;
  
  // P2P 1:1 partner tracking
  String? _p2pPartnerId;
  String? _p2pPartnerName;

  // Selected hardware config
  String? _selectedAudioInputId;
  List<MediaDeviceInfo> _audioDevices = [];

  // Track metadata mapping sent by the server: TrackID -> (UserID, Username)
  final Map<String, Map<String, String>> _trackMetadata = {};
  
  // Active remote participants
  final List<RemoteParticipant> _remoteParticipants = [];

  bool get isConnected => _isConnected;
  bool get isJoined => _isJoined;
  bool get isMuted => _isMuted;
  bool get isCameraOn => _isCameraOn;
  String? get roomId => _roomId;
  String? get callType => _callType;
  List<RemoteParticipant> get remoteParticipants => _remoteParticipants;
  MediaStream? get localStream => _localStream;
  RTCVideoRenderer? get localRenderer => _localRenderer;
  List<MediaDeviceInfo> get audioDevices => _audioDevices;
  String? get selectedAudioInputId => _selectedAudioInputId;

  // Fetch list of available audio input devices
  Future<void> loadAudioDevices() async {
    try {
      final devices = await navigator.mediaDevices.enumerateDevices();
      _audioDevices = devices.where((d) => d.kind == 'audioinput').toList();
      if (_audioDevices.isNotEmpty && _selectedAudioInputId == null) {
        _selectedAudioInputId = _audioDevices.first.deviceId;
      }
      notifyListeners();
    } catch (e) {
      debugPrint("Error loading audio devices: $e");
    }
  }

  // Set selected device and hot-swap local stream
  Future<void> setAudioInputDevice(String deviceId) async {
    _selectedAudioInputId = deviceId;
    notifyListeners();
    if (_localStream != null) {
      // Re-capture local media with the new device ID
      await _reacquireLocalStream();
    }
  }

  // Connect to Go backend signaling socket
  Future<void> connect(
    String wsUrl, 
    String roomId, 
    String token, 
    String username, {
    required String callType,
    int maxParticipants = 4,
    int timeLimitMinutes = 40,
  }) async {
    _roomId = roomId;
    _callType = callType;
    notifyListeners();

    try {
      debugPrint("Connecting to WebSocket: $wsUrl");
      _channel = WebSocketChannel.connect(Uri.parse(wsUrl));
      _isConnected = true;
      notifyListeners();

      // Start listening to WebSocket messages
      _channel!.stream.listen(
        (message) => _handleSignalingMessage(message),
        onError: (e) {
          debugPrint("WebSocket error: $e");
          _cleanup();
        },
        onDone: () {
          debugPrint("WebSocket connection closed.");
          _cleanup();
        },
      );

      // Send join event
      final joinPayload = {
        'type': 'join',
        'payload': {
          'roomId': roomId,
          'token': token,
          'username': username,
          'callType': callType,
          'maxParticipants': maxParticipants,
          'timeLimitMinutes': timeLimitMinutes,
        }
      };
      _channel!.sink.add(jsonEncode(joinPayload));
    } catch (e) {
      debugPrint("Connection failed: $e");
      _cleanup();
    }
  }

  // Handle incoming signaling messages from server
  Future<void> _handleSignalingMessage(dynamic message) async {
    final Map<String, dynamic> msg = jsonDecode(message);
    final String type = msg['type'];
    final dynamic payload = msg['payload'];

    debugPrint("Received signaling event: $type");

    switch (type) {
      case 'joined':
        _isJoined = true;
        _myUserId = payload['userId'];
        _callType = payload['callType'];
        debugPrint("Joined successfully. UID: $_myUserId, CallType: $_callType");
        notifyListeners();

        // 1. Initialize local preview renderer
        _localRenderer = RTCVideoRenderer();
        await _localRenderer!.initialize();

        // 2. Setup Local Stream
        await _acquireLocalStream();

        // 3. Setup Connection
        if (_callType == 'sfu') {
          await _initializeSFUPeerConnection();
        }
        break;

      case 'user_joined':
        final String userId = payload['userId'];
        final String username = payload['username'];
        debugPrint("User joined the room: $username ($userId)");

        if (_callType == 'p2p') {
          _p2pPartnerId = userId;
          _p2pPartnerName = username;
          // The host (who is already in room) initiates P2P connection when guest joins
          await _initializeP2PPeerConnection(userId, isOfferer: true);
        }
        break;

      case 'track_info':
        final String trackId = payload['trackId'];
        final String userId = payload['userId'];
        final String username = payload['username'];
        _trackMetadata[trackId] = {
          'userId': userId,
          'username': username,
        };
        break;

      case 'offer':
        final String sdp = payload['sdp'];
        final String? senderUserId = payload['senderUserId'];

        if (_callType == 'p2p') {
          if (senderUserId != null) {
            _p2pPartnerId = senderUserId;
          }
          await _initializeP2PPeerConnection(_p2pPartnerId ?? 'partner', isOfferer: false);
        }

        if (_peerConnection == null) return;
        await _peerConnection!.setRemoteDescription(
          RTCSessionDescription(sdp, 'offer'),
        );
        final answer = await _peerConnection!.createAnswer({});
        await _peerConnection!.setLocalDescription(answer);
        
        // Send Answer back
        if (_callType == 'p2p') {
          _channel!.sink.add(jsonEncode({
            'type': 'answer',
            'payload': {
              'sdp': answer.sdp,
              'targetUserId': _p2pPartnerId,
            }
          }));
        } else {
          _channel!.sink.add(jsonEncode({
            'type': 'answer',
            'payload': {'sdp': answer.sdp}
          }));
        }
        break;

      case 'answer':
        if (_peerConnection == null) return;
        final String sdp = payload['sdp'];
        await _peerConnection!.setRemoteDescription(
          RTCSessionDescription(sdp, 'answer'),
        );
        break;

      case 'candidate':
        if (_peerConnection == null) return;
        final Map<String, dynamic> candidateMap = payload['candidate'];
        await _peerConnection!.addCandidate(
          RTCIceCandidate(
            candidateMap['candidate'],
            candidateMap['sdpMid'],
            candidateMap['sdpMLineIndex'],
          ),
        );
        break;

      case 'leave':
        final String userId = payload['userId'];
        debugPrint("Participant left: $userId");
        _removeParticipantByUserId(userId);
        if (_callType == 'p2p' && userId == _p2pPartnerId) {
          _cleanupPeerConnectionOnly();
        }
        break;

      case 'call_ended':
        debugPrint("Call terminated by server: ${payload['reason']}");
        _cleanup();
        break;

      case 'error':
        debugPrint("Signaling error: ${payload['error']}");
        _cleanup();
        break;
    }
  }

  // Set up local MediaStream containing raw audio and ideal video
  Future<void> _acquireLocalStream() async {
    final Map<String, dynamic> mediaConstraints = {
      'audio': {
        'noiseSuppression': false,
        'autoGainControl': false,
        'echoCancellation': false,
        'channelCount': 2,
        if (_selectedAudioInputId != null) 'deviceId': {'exact': _selectedAudioInputId},
      },
      'video': {
        'facingMode': 'user',
        'width': {'ideal': 640},
        'height': {'ideal': 480},
        'frameRate': {'ideal': 24},
      },
    };

    try {
      _localStream = await navigator.mediaDevices.getUserMedia(mediaConstraints);
      _localRenderer!.srcObject = _localStream;
      notifyListeners();
    } catch (e) {
      debugPrint("Camera/Microphone capture failed: $e");
    }
  }

  // Hot-swap audio tracks on device selection change
  Future<void> _reacquireLocalStream() async {
    if (_localStream == null) return;

    final oldTracks = _localStream!.getTracks();
    for (var track in oldTracks) {
      track.stop();
      if (_peerConnection != null) {
        // Remove old track from sender if active
        final senders = await _peerConnection!.getSenders();
        for (var sender in senders) {
          if (sender.track?.id == track.id) {
            await _peerConnection!.removeTrack(sender);
          }
        }
      }
    }

    await _acquireLocalStream();

    if (_peerConnection != null && _localStream != null) {
      _localStream!.getTracks().forEach((track) {
        _peerConnection!.addTrack(track, _localStream!);
      });
      // Trigger local renegotiation
      if (_callType == 'sfu') {
        final offer = await _peerConnection!.createOffer({});
        await _peerConnection!.setLocalDescription(offer);
        _channel!.sink.add(jsonEncode({
          'type': 'offer',
          'payload': {'sdp': offer.sdp}
        }));
      }
    }
  }

  // Initialize standard SFU connection (media is managed by pion server)
  Future<void> _initializeSFUPeerConnection() async {
    final Map<String, dynamic> config = {
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'}
      ]
    };

    _peerConnection = await createPeerConnection(config, {});

    if (_localStream != null) {
      _localStream!.getTracks().forEach((track) {
        _peerConnection!.addTrack(track, _localStream!);
      });
    }

    _peerConnection!.onIceCandidate = (candidate) {
      if (candidate == null) return;
      _channel!.sink.add(jsonEncode({
        'type': 'candidate',
        'payload': {
          'candidate': {
            'candidate': candidate.candidate,
            'sdpMid': candidate.sdpMid,
            'sdpMLineIndex': candidate.sdpMLineIndex,
          }
        }
      }));
    };

    _peerConnection!.onTrack = (RTCTrackEvent event) async {
      if (event.streams.isEmpty) return;
      final MediaStream stream = event.streams.first;
      final String trackId = event.track.id!;

      final metadata = _trackMetadata[trackId];
      final String userId = metadata?['userId'] ?? 'unknown_user';
      final String username = metadata?['username'] ?? 'User ($userId)';

      // Check if participant already exists in room, and merge track (audio+video)
      final existingIndex = _remoteParticipants.indexWhere((p) => p.userId == userId);

      if (existingIndex != -1) {
        final existing = _remoteParticipants[existingIndex];
        existing.stream.addTrack(event.track);
        existing.renderer.srcObject = existing.stream;
        notifyListeners();
      } else {
        final renderer = RTCVideoRenderer();
        await renderer.initialize();
        renderer.srcObject = stream;

        final newParticipant = RemoteParticipant(
          userId: userId,
          username: username,
          trackId: trackId,
          stream: stream,
          renderer: renderer,
        );

        _remoteParticipants.add(newParticipant);
        notifyListeners();
      }
    };

    final offer = await _peerConnection!.createOffer({});
    await _peerConnection!.setLocalDescription(offer);
    _channel!.sink.add(jsonEncode({
      'type': 'offer',
      'payload': {'sdp': offer.sdp}
    }));
  }

  // Initialize P2P connection (media goes directly to the peer)
  Future<void> _initializeP2PPeerConnection(String targetUserId, {required bool isOfferer}) async {
    if (_peerConnection != null) return; // Already initialized

    debugPrint("Initializing P2P connection with: $targetUserId. Offerer: $isOfferer");

    final Map<String, dynamic> config = {
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'}
      ]
    };

    _peerConnection = await createPeerConnection(config, {});

    if (_localStream != null) {
      _localStream!.getTracks().forEach((track) {
        _peerConnection!.addTrack(track, _localStream!);
      });
    }

    _peerConnection!.onIceCandidate = (candidate) {
      if (candidate == null) return;
      _channel!.sink.add(jsonEncode({
        'type': 'candidate',
        'payload': {
          'targetUserId': targetUserId,
          'candidate': {
            'candidate': candidate.candidate,
            'sdpMid': candidate.sdpMid,
            'sdpMLineIndex': candidate.sdpMLineIndex,
          }
        }
      }));
    };

    _peerConnection!.onTrack = (RTCTrackEvent event) async {
      if (event.streams.isEmpty) return;
      final MediaStream stream = event.streams.first;

      final existingIndex = _remoteParticipants.indexWhere((p) => p.userId == targetUserId);

      if (existingIndex != -1) {
        final existing = _remoteParticipants[existingIndex];
        existing.stream.addTrack(event.track);
        existing.renderer.srcObject = existing.stream;
        notifyListeners();
      } else {
        final renderer = RTCVideoRenderer();
        await renderer.initialize();
        renderer.srcObject = stream;

        final newParticipant = RemoteParticipant(
          userId: targetUserId,
          username: _p2pPartnerName ?? 'Partner',
          trackId: event.track.id ?? 'p2p_track',
          stream: stream,
          renderer: renderer,
        );

        _remoteParticipants.add(newParticipant);
        notifyListeners();
      }
    };

    if (isOfferer) {
      final offer = await _peerConnection!.createOffer({});
      await _peerConnection!.setLocalDescription(offer);
      _channel!.sink.add(jsonEncode({
        'type': 'offer',
        'payload': {
          'sdp': offer.sdp,
          'targetUserId': targetUserId,
        }
      }));
    }
  }

  // Adjust volume for a specific remote participant
  void setParticipantVolume(String userId, double volume) {
    final idx = _remoteParticipants.indexWhere((p) => p.userId == userId);
    if (idx != -1) {
      _remoteParticipants[idx].setVolume(volume);
      notifyListeners();
    }
  }

  // Toggle local mute
  void toggleMute() {
    if (_localStream != null) {
      final audioTracks = _localStream!.getAudioTracks();
      if (audioTracks.isNotEmpty) {
        _isMuted = !_isMuted;
        audioTracks.first.enabled = !_isMuted;
        notifyListeners();
      }
    }
  }

  // Toggle local camera
  void toggleCamera() {
    if (_localStream != null) {
      final videoTracks = _localStream!.getVideoTracks();
      if (videoTracks.isNotEmpty) {
        _isCameraOn = !_isCameraOn;
        videoTracks.first.enabled = _isCameraOn;
        notifyListeners();
      }
    }
  }

  // Helper to remove participant
  void _removeParticipantByUserId(String userId) {
    final int index = _remoteParticipants.indexWhere((p) => p.userId == userId);
    if (index != -1) {
      final p = _remoteParticipants.removeAt(index);
      p.dispose();
      notifyListeners();
    }
  }

  void _cleanupPeerConnectionOnly() {
    if (_peerConnection != null) {
      _peerConnection!.close();
      _peerConnection = null;
    }
  }

  // Leave room and clean up
  Future<void> leave() async {
    _cleanup();
  }

  void _cleanup() {
    _isConnected = false;
    _isJoined = false;
    _isMuted = false;
    _isCameraOn = true;
    _roomId = null;
    _callType = null;
    _myUserId = null;
    _p2pPartnerId = null;
    _p2pPartnerName = null;

    for (var p in _remoteParticipants) {
      p.dispose();
    }
    _remoteParticipants.clear();
    _trackMetadata.clear();

    if (_localStream != null) {
      _localStream!.getTracks().forEach((track) => track.stop());
      _localStream = null;
    }

    if (_localRenderer != null) {
      _localRenderer!.srcObject = null;
      _localRenderer!.dispose();
      _localRenderer = null;
    }

    _cleanupPeerConnectionOnly();

    if (_channel != null) {
      _channel!.sink.close();
      _channel = null;
    }
    
    notifyListeners();
  }
}
