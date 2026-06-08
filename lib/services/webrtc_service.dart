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

  RemoteParticipant({
    required this.userId,
    required this.username,
    required this.trackId,
    required this.stream,
    required this.renderer,
  });

  Future<void> dispose() async {
    renderer.srcObject = null;
    await renderer.dispose();
  }
}

class WebRTCService extends ChangeNotifier {
  WebSocketChannel? _channel;
  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  
  bool _isConnected = false;
  bool _isJoined = false;
  bool _isMuted = false;
  String? _roomId;
  
  // Track metadata mapping sent by the server: TrackID -> (UserID, Username)
  final Map<String, Map<String, String>> _trackMetadata = {};
  
  // Active remote participants
  final List<RemoteParticipant> _remoteParticipants = [];

  bool get isConnected => _isConnected;
  bool get isJoined => _isJoined;
  bool get isMuted => _isMuted;
  String? get roomId => _roomId;
  List<RemoteParticipant> get remoteParticipants => _remoteParticipants;
  MediaStream? get localStream => _localStream;

  // Connect to Go backend signaling socket
  Future<void> connect(String wsUrl, String roomId, String token, String username) async {
    _roomId = roomId;
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
        debugPrint("Successfully joined Room! Status: ${payload['status']}");
        _isJoined = true;
        notifyListeners();
        // Initialize PeerConnection and publish audio
        await _initializePeerConnection();
        break;

      case 'track_info':
        final String trackId = payload['trackId'];
        final String userId = payload['userId'];
        final String username = payload['username'];
        debugPrint("Received track info: Track=$trackId belongs to User=$userId ($username)");
        _trackMetadata[trackId] = {
          'userId': userId,
          'username': username,
        };
        break;

      case 'offer':
        if (_peerConnection == null) return;
        final String sdp = payload['sdp'];
        await _peerConnection!.setRemoteDescription(
          RTCSessionDescription(sdp, 'offer'),
        );
        final answer = await _peerConnection!.createAnswer({});
        await _peerConnection!.setLocalDescription(answer);
        
        // Send Answer back
        _channel!.sink.add(jsonEncode({
          'type': 'answer',
          'payload': {'sdp': answer.sdp}
        }));
        debugPrint("Sent Answer back to server.");
        break;

      case 'answer':
        if (_peerConnection == null) return;
        final String sdp = payload['sdp'];
        await _peerConnection!.setRemoteDescription(
          RTCSessionDescription(sdp, 'answer'),
        );
        debugPrint("Set remote description (Answer).");
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
        debugPrint("Added remote ICE candidate.");
        break;

      case 'leave':
        final String userId = payload['userId'];
        debugPrint("Participant left: $userId");
        _removeParticipantByUserId(userId);
        break;

      case 'error':
        debugPrint("Error from signaling server: ${payload['error']}");
        break;
    }
  }

  // Initialize WebRTC Peer Connection and publish raw audio
  Future<void> _initializePeerConnection() async {
    final Map<String, dynamic> config = {
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'}
      ]
    };

    final Map<String, dynamic> constraints = {
      'mandatory': {},
      'optional': [
        {'DtlsSrtpKeyAgreement': true}
      ]
    };

    _peerConnection = await createPeerConnection(config, constraints);

    // Setup Local Audio Media Stream
    final Map<String, dynamic> mediaConstraints = {
      'audio': {
        'noiseSuppression': false,
        'autoGainControl': false,
        'echoCancellation': false,
        'channelCount': 2,
      },
      'video': false,
    };

    try {
      _localStream = await navigator.mediaDevices.getUserMedia(mediaConstraints);
      debugPrint("Captured local microphone with constraints: noiseSuppression=false, autoGainControl=false, echoCancellation=false, channelCount=2.");
      
      _localStream!.getTracks().forEach((track) {
        _peerConnection!.addTrack(track, _localStream!);
      });
    } catch (e) {
      debugPrint("Microphone capture failed (or denied): $e");
    }

    // Handle Local ICE Candidates
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

    // Handle incoming Remote Tracks
    _peerConnection!.onTrack = (RTCTrackEvent event) async {
      debugPrint("Received remote track from peer: Streams=${event.streams.length}, Track=${event.track.id}, Kind=${event.track.kind}");
      if (event.streams.isEmpty || event.track.kind != 'audio') return;

      final MediaStream stream = event.streams.first;
      final String trackId = event.track.id!;

      // Lookup owner info
      final metadata = _trackMetadata[trackId];
      final String userId = metadata?['userId'] ?? 'unknown_user';
      final String username = metadata?['username'] ?? 'User ($userId)';

      // Create video renderer to play out the remote audio track
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
    };

    _peerConnection!.onConnectionState = (state) {
      debugPrint("WebRTC Connection State: $state");
    };

    // Create and Send Offer
    final offer = await _peerConnection!.createOffer({});
    await _peerConnection!.setLocalDescription(offer);

    _channel!.sink.add(jsonEncode({
      'type': 'offer',
      'payload': {'sdp': offer.sdp}
    }));
    debugPrint("Sent initial SDP Offer to server.");
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

  // Helper to remove participant
  void _removeParticipantByUserId(String userId) {
    final int index = _remoteParticipants.indexWhere((p) => p.userId == userId);
    if (index != -1) {
      final p = _remoteParticipants.removeAt(index);
      p.dispose();
      notifyListeners();
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
    _roomId = null;

    for (var p in _remoteParticipants) {
      p.dispose();
    }
    _remoteParticipants.clear();
    _trackMetadata.clear();

    if (_localStream != null) {
      _localStream!.getTracks().forEach((track) => track.stop());
      _localStream = null;
    }

    if (_peerConnection != null) {
      _peerConnection!.close();
      _peerConnection = null;
    }

    if (_channel != null) {
      _channel!.sink.close();
      _channel = null;
    }
    
    notifyListeners();
  }
}
