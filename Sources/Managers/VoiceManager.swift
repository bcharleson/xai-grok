import Foundation
import AVFoundation
import Combine
#if os(macOS)
import CoreAudio
import AppKit
#endif

/// VoiceManager handles xAI Voice API WebSocket connection for speech-to-text and text-to-speech in Code Mode
/// WebSocket endpoint: wss://api.x.ai/v1/realtime
///
/// BUFFERED APPROACH (v2): Records complete audio session locally, then sends all at once for transcription.
/// This provides better accuracy than real-time streaming by giving the AI full context.
class VoiceManager: NSObject, ObservableObject {

    // MARK: - Published State
    @Published var isConnected = false
    @Published var isRecording = false
    @Published var isProcessing = false
    @Published var isConnecting = false  // NEW: Track connection in progress
    @Published var transcribedText = ""
    @Published var errorMessage: String?
    @Published var permissionStatus: AVAuthorizationStatus = .notDetermined

    /// Incremented each time a complete transcription is received
    /// Observe this with onChange to react to new transcriptions
    @Published var transcriptionVersion: Int = 0

    // Transcription state tracking
    private var isWaitingForTranscription = false
    private var transcriptionTimeout: DispatchWorkItem?
    @Published var isSpeaking = false
    @Published var isTTSEnabled = true
    @Published var audioLevel: Float = 0.0 // For waveform visualization (0.0 to 1.0)

    // MARK: - Audio Configuration
    private let sampleRate: Double = 24000 // 24kHz for voice
    private let channelCount: AVAudioChannelCount = 1 // Mono

    // MARK: - Private Properties
    private var webSocket: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var apiKey: String = ""

    // Audio capture (STT)
    private var audioEngine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?

    // MARK: - Buffered Recording (v2)
    /// Buffer to accumulate all audio during recording session
    private var recordingBuffer: Data = Data()
    /// Target audio format for transcription (16-bit PCM at 24kHz mono)
    private var targetAudioFormat: AVAudioFormat?
    /// Audio converter for format conversion
    private var audioConverter: AVAudioConverter?

    // Audio playback (TTS)
    private var audioPlayer: AVAudioPlayer?
    private var audioPlayerQueue: AVQueuePlayer?
    private var audioDataBuffer: Data = Data()

    // Callbacks
    var onTranscription: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onSpeechStart: (() -> Void)?
    var onSpeechEnd: (() -> Void)?

    // Voice personality (default: Ara - warm, friendly)
    var voicePersonality: String = "Ara"
    
    // MARK: - Initialization
    override init() {
        super.init()
        checkMicrophonePermission()
    }
    
    // MARK: - API Key Configuration
    func setAPIKey(_ key: String) {
        self.apiKey = key
    }
    
    // MARK: - Microphone Permission
    func checkMicrophonePermission() {
        permissionStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    }
    
    func requestMicrophonePermission(completion: @escaping (Bool) -> Void) {
        // Check current status first - if already denied, don't request again
        let currentStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if currentStatus == .denied {
            DispatchQueue.main.async {
                self.permissionStatus = .denied
                completion(false)
            }
            return
        }
        
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                self?.permissionStatus = granted ? .authorized : .denied
                completion(granted)
            }
        }
    }
    
    /// Opens System Settings to the Microphone privacy settings
    func openMicrophoneSettings() {
        #if os(macOS)
        // Open System Settings to Microphone privacy pane
        // For macOS 13+ (Ventura and later): Use the new URL format
        // For macOS 12 and earlier: Same URL format works
        let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        } else {
            // Fallback: Just open System Settings
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/PreferencePanes/Security.prefPane"))
        }
        #endif
    }
    
    // MARK: - WebSocket Connection
    func connect() {
        #if DEBUG
        print("🔌 connect() called")
        print("   Current state: isConnected=\(isConnected), isConnecting=\(isConnecting)")
        #endif

        guard !apiKey.isEmpty else {
            errorMessage = "API key not set"
            #if DEBUG
            print("❌ No API key configured")
            #endif
            return
        }

        guard let url = URL(string: "wss://api.x.ai/v1/realtime") else {
            errorMessage = "Invalid WebSocket URL"
            #if DEBUG
            print("❌ Invalid WebSocket URL")
            #endif
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let config = URLSessionConfiguration.default
        urlSession = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        webSocket = urlSession?.webSocketTask(with: request)

        #if DEBUG
        print("🔌 WebSocket task created, calling resume()...")
        #endif

        webSocket?.resume()
        receiveMessage()

        #if DEBUG
        print("🔌 WebSocket resumed, waiting for connection...")
        #endif

        // Session config will be sent in didOpenWithProtocol delegate method
    }
    
    func disconnect() {
        stopRecording()
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil

        // Synchronously reset all connection-related state for immediate UI consistency
        // The delegate's didCloseWith will also set these, but we set them here
        // to avoid UI inconsistencies between disconnect() and the async delegate callback
        isConnected = false
        isConnecting = false
        isProcessing = false
        isWaitingForTranscription = false

        // Cancel any pending transcription timeout
        transcriptionTimeout?.cancel()
        transcriptionTimeout = nil

        #if DEBUG
        print("🔌 Disconnected - all connection state reset")
        #endif
    }
    
    // MARK: - Session Configuration
    private func sendSessionConfig() {
        // Configure session for transcription-only mode with DISABLED VAD
        // BUFFERED APPROACH: We control when audio starts/stops, not the server
        // This gives us complete sentences instead of fragmented transcription
        let config: [String: Any] = [
            "type": "session.update",
            "session": [
                // CRITICAL: Include both "text" and "audio" modalities to enable transcription
                // Even though we only want text output, we need "audio" to process input audio
                "modalities": ["text", "audio"],
                "input_audio_format": "pcm16",
                "output_audio_format": "pcm16",
                "voice": voicePersonality.lowercased(),
                "input_audio_transcription": [
                    "model": "whisper-1"
                ],
                // DISABLED: Server-side VAD causes fragmented transcription
                // We use manual control (user clicks to start/stop) instead
                "turn_detection": NSNull(),  // Disable automatic turn detection
                "tools": [],
                "tool_choice": "auto"
            ]
        ]

        sendJSON(config)

        #if DEBUG
        print("🎤 Session configured:")
        print("   - Modalities: text + audio (for transcription)")
        print("   - Turn detection: DISABLED (manual control)")
        print("   - Input audio transcription: whisper-1")
        #endif
    }
    
    // MARK: - Message Handling
    private func sendJSON(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let jsonString = String(data: data, encoding: .utf8) else {
            #if DEBUG
            print("⚠️ Failed to serialize JSON for sending")
            #endif
            return
        }

        // Log outgoing message type (truncate audio data)
        #if DEBUG
        if let msgType = object["type"] as? String {
            if msgType == "input_audio_buffer.append" {
                print("📤 Sending: \(msgType) (\(jsonString.count) chars)")
            } else {
                print("📤 Sending: \(msgType)")
            }
        }
        #endif

        webSocket?.send(.string(jsonString)) { [weak self] error in
            if let error = error {
                DispatchQueue.main.async {
                    self?.errorMessage = "Send error: \(error.localizedDescription)"
                    #if DEBUG
                    print("❌ WebSocket send error: \(error.localizedDescription)")
                    #endif
                }
            }
        }
    }
    
    private func receiveMessage() {
        webSocket?.receive { [weak self] result in
            switch result {
            case .success(let message):
                // CRITICAL: Handle message on main thread to ensure @Published updates trigger SwiftUI
                DispatchQueue.main.async {
                    self?.handleMessage(message)
                }
                self?.receiveMessage() // Continue receiving
            case .failure(let error):
                DispatchQueue.main.async {
                    self?.errorMessage = "Receive error: \(error.localizedDescription)"
                    self?.isConnected = false
                }
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            parseServerEvent(text)
        case .data(let data):
            if let text = String(data: data, encoding: .utf8) {
                parseServerEvent(text)
            }
        @unknown default:
            break
        }
    }

    private func parseServerEvent(_ jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let eventType = json["type"] as? String else {
            #if DEBUG
            print("⚠️ Failed to parse WebSocket message: \(jsonString.prefix(200))")
            #endif
            return
        }

        #if DEBUG
        // Log all events for debugging (truncate for brevity)
        print("📨 WS Event: \(eventType)")
        #endif

        DispatchQueue.main.async { [weak self] in
            switch eventType {
            case "session.created", "session.updated":
                self?.isConnected = true
                #if DEBUG
                print("🎤 Voice session established")
                #endif

            case "input_audio_buffer.speech_started":
                self?.isProcessing = true
                #if DEBUG
                print("🎤 Speech detected")
                #endif

            case "input_audio_buffer.speech_stopped":
                #if DEBUG
                print("🎤 Speech ended, processing...")
                #endif

            case "input_audio_buffer.committed":
                #if DEBUG
                print("🎤 Audio buffer committed - transcription should follow")
                #endif

            case "conversation.item.created":
                #if DEBUG
                print("📥 conversation.item.created")
                if let item = json["item"] as? [String: Any] {
                    print("   item type: \(item["type"] ?? "unknown")")
                    print("   item id: \(item["id"] ?? "unknown")")
                }
                #endif

            case "conversation.item.input_audio_transcription.completed":
                #if DEBUG
                print("📥 conversation.item.input_audio_transcription.completed received")
                print("   JSON keys: \(json.keys)")
                print("   Thread: \(Thread.isMainThread ? "MAIN" : "BACKGROUND")")
                #endif

                if let transcript = json["transcript"] as? String, !transcript.isEmpty {
                    // Cancel timeout since we got the transcription
                    self?.transcriptionTimeout?.cancel()
                    self?.isWaitingForTranscription = false
                    self?.isProcessing = false

                    let oldVersion = self?.transcriptionVersion ?? 0
                    self?.transcribedText = transcript
                    self?.transcriptionVersion += 1  // Signal complete transcription
                    self?.onTranscription?(transcript)

                    #if DEBUG
                    print("✅ Transcription received: '\(transcript)'")
                    print("   transcriptionVersion: \(oldVersion) → \(self?.transcriptionVersion ?? -1)")
                    print("   Thread: \(Thread.isMainThread ? "MAIN ✓" : "BACKGROUND ✗")")
                    #endif
                } else {
                    #if DEBUG
                    print("⚠️ conversation.item.input_audio_transcription.completed but transcript is empty or missing")
                    #endif
                }

            case "conversation.item.input_audio_transcription.delta":
                // Handle streaming transcription deltas
                if let delta = json["delta"] as? String {
                    self?.transcribedText += delta
                    #if DEBUG
                    print("📝 Transcription delta: '\(delta)'")
                    #endif
                }

            case "response.audio_transcript.delta":
                if let delta = json["delta"] as? String {
                    self?.transcribedText += delta
                }

            case "response.audio_transcript.done":
                if let transcript = json["transcript"] as? String {
                    self?.transcribedText = transcript
                    self?.transcriptionVersion += 1  // Signal complete transcription
                    self?.onTranscription?(transcript)
                    self?.isProcessing = false
                }

            // Handle output audio transcript (with "output_" prefix)
            case "response.output_audio_transcript.delta":
                if let delta = json["delta"] as? String {
                    self?.transcribedText += delta
                    #if DEBUG
                    print("📝 Output audio transcript delta: \(delta)")
                    #endif
                }

            case "response.output_audio_transcript.done":
                if let transcript = json["transcript"] as? String, !transcript.isEmpty {
                    // Cancel timeout since we got the transcription
                    self?.transcriptionTimeout?.cancel()
                    self?.isWaitingForTranscription = false
                    self?.isProcessing = false

                    let oldVersion = self?.transcriptionVersion ?? 0
                    self?.transcribedText = transcript
                    self?.transcriptionVersion += 1  // Signal complete transcription
                    self?.onTranscription?(transcript)

                    #if DEBUG
                    print("✅ Output audio transcription complete: '\(transcript)'")
                    print("   transcriptionVersion: \(oldVersion) → \(self?.transcriptionVersion ?? -1)")
                    print("   Thread: \(Thread.isMainThread ? "MAIN ✓" : "BACKGROUND ✗")")
                    #endif
                } else {
                    #if DEBUG
                    print("⚠️ response.output_audio_transcript.done but transcript is empty")
                    #endif
                }

            // BUFFERED MODE: Handle text response (we request text-only modality)
            case "response.text.delta":
                if let delta = json["delta"] as? String {
                    self?.transcribedText += delta
                    #if DEBUG
                    print("📝 Text delta: \(delta)")
                    #endif
                }

            case "response.text.done":
                // Final text from response - this is our transcription
                #if DEBUG
                print("📥 response.text.done received, JSON keys: \(json.keys)")
                print("   Thread: \(Thread.isMainThread ? "MAIN" : "BACKGROUND")")
                #endif
                if let text = json["text"] as? String, !text.isEmpty {
                    // Cancel timeout since we got the transcription
                    self?.transcriptionTimeout?.cancel()
                    self?.isWaitingForTranscription = false
                    self?.isProcessing = false

                    let oldVersion = self?.transcriptionVersion ?? 0
                    self?.transcribedText = text
                    self?.transcriptionVersion += 1  // Signal complete transcription
                    self?.onTranscription?(text)

                    #if DEBUG
                    print("✅ Complete transcription: '\(text)'")
                    print("   transcriptionVersion: \(oldVersion) → \(self?.transcriptionVersion ?? -1)")
                    print("   Thread: \(Thread.isMainThread ? "MAIN ✓" : "BACKGROUND ✗")")
                    #endif
                } else {
                    #if DEBUG
                    print("⚠️ response.text.done but no 'text' field found")
                    print("   Available keys: \(json.keys)")
                    #endif
                }

            case "response.audio.delta":
                // Handle streaming audio response from Grok
                if let audioBase64 = json["delta"] as? String,
                   self?.isTTSEnabled == true {
                    self?.appendAudioData(audioBase64)
                }

            case "response.audio.done":
                // Audio response complete, play accumulated audio
                if self?.isTTSEnabled == true {
                    self?.playAccumulatedAudio()
                }
                #if DEBUG
                print("🔊 TTS audio response complete")
                #endif

            case "response.done":
                // Response fully complete - check if we have transcription
                self?.transcriptionTimeout?.cancel()
                self?.isWaitingForTranscription = false
                self?.isProcessing = false

                #if DEBUG
                print("🎤 response.done received")
                print("   Thread: \(Thread.isMainThread ? "MAIN" : "BACKGROUND")")
                print("   transcribedText: '\(self?.transcribedText ?? "nil")'")
                print("   transcriptionVersion before: \(self?.transcriptionVersion ?? -1)")

                // Log the full response for debugging
                if let response = json["response"] as? [String: Any] {
                    print("   response object found with keys: \(response.keys)")
                    if let output = response["output"] as? [[String: Any]] {
                        for (idx, outputItem) in output.enumerated() {
                            print("   output[\(idx)] type: \(outputItem["type"] ?? "unknown")")
                            if let content = outputItem["content"] as? [[String: Any]] {
                                for (cidx, contentItem) in content.enumerated() {
                                    print("   output[\(idx)].content[\(cidx)]: \(contentItem)")
                                }
                            }
                        }
                    }
                }
                #endif

                // Check if we accumulated transcribed text via deltas
                if let text = self?.transcribedText, !text.isEmpty {
                    // Increment version to signal complete transcription (fallback if .done events didn't fire)
                    let oldVersion = self?.transcriptionVersion ?? 0
                    self?.transcriptionVersion += 1
                    self?.onTranscription?(text)
                    #if DEBUG
                    print("✅ Transcription via response.done: '\(text)'")
                    print("   transcriptionVersion changed: \(oldVersion) → \(self?.transcriptionVersion ?? -1)")
                    print("   Thread: \(Thread.isMainThread ? "MAIN ✓" : "BACKGROUND ✗")")
                    #endif
                } else {
                    #if DEBUG
                    print("⚠️ response.done but transcribedText is empty or nil")
                    #endif
                }

            // Handle response.output_item.done - contains the full response content
            case "response.output_item.done":
                #if DEBUG
                print("📥 response.output_item.done received")
                print("   Thread: \(Thread.isMainThread ? "MAIN" : "BACKGROUND")")
                if let item = json["item"] as? [String: Any] {
                    print("   item keys: \(item.keys)")
                    if let content = item["content"] as? [[String: Any]] {
                        print("   content array count: \(content.count)")
                        for (idx, part) in content.enumerated() {
                            print("   content[\(idx)] keys: \(part.keys)")
                        }
                    }
                }
                #endif

                // Extract content from the item - try multiple possible structures
                if let item = json["item"] as? [String: Any] {
                    var transcriptText: String?

                    // Try 1: Check for direct transcript field in item
                    if let transcript = item["transcript"] as? String, !transcript.isEmpty {
                        transcriptText = transcript
                        #if DEBUG
                        print("   Found transcript in item.transcript")
                        #endif
                    }

                    // Try 2: Check content array for text or transcript
                    if transcriptText == nil, let content = item["content"] as? [[String: Any]] {
                        for contentPart in content {
                            // Try text field
                            if let text = contentPart["text"] as? String, !text.isEmpty {
                                transcriptText = text
                                #if DEBUG
                                print("   Found transcript in content[].text")
                                #endif
                                break
                            }
                            // Try transcript field
                            if let transcript = contentPart["transcript"] as? String, !transcript.isEmpty {
                                transcriptText = transcript
                                #if DEBUG
                                print("   Found transcript in content[].transcript")
                                #endif
                                break
                            }
                        }
                    }

                    // If we found transcription, process it
                    if let text = transcriptText {
                        self?.transcriptionTimeout?.cancel()
                        self?.isWaitingForTranscription = false
                        self?.isProcessing = false

                        let oldVersion = self?.transcriptionVersion ?? 0
                        self?.transcribedText = text
                        self?.transcriptionVersion += 1
                        self?.onTranscription?(text)

                        #if DEBUG
                        print("✅ Transcription from output_item: '\(text)'")
                        print("   transcriptionVersion: \(oldVersion) → \(self?.transcriptionVersion ?? -1)")
                        print("   Thread: \(Thread.isMainThread ? "MAIN ✓" : "BACKGROUND ✗")")
                        #endif
                    } else {
                        #if DEBUG
                        print("⚠️ response.output_item.done but no transcript found in any expected location")
                        #endif
                    }
                }

            // Handle response.content_part.done - alternative content format
            case "response.content_part.done":
                #if DEBUG
                print("📥 response.content_part.done received")
                print("   Thread: \(Thread.isMainThread ? "MAIN" : "BACKGROUND")")
                #endif
                if let part = json["part"] as? [String: Any],
                   let text = part["text"] as? String, !text.isEmpty {
                    self?.transcriptionTimeout?.cancel()
                    self?.isWaitingForTranscription = false
                    self?.isProcessing = false

                    let oldVersion = self?.transcriptionVersion ?? 0
                    self?.transcribedText = text
                    self?.transcriptionVersion += 1
                    self?.onTranscription?(text)

                    #if DEBUG
                    print("✅ Transcription from content_part: '\(text)'")
                    print("   transcriptionVersion: \(oldVersion) → \(self?.transcriptionVersion ?? -1)")
                    print("   Thread: \(Thread.isMainThread ? "MAIN ✓" : "BACKGROUND ✗")")
                    #endif
                }

            case "error":
                if let error = json["error"] as? [String: Any],
                   let message = error["message"] as? String {
                    self?.errorMessage = message
                    self?.isProcessing = false
                    self?.isWaitingForTranscription = false
                    #if DEBUG
                    print("🎤 Voice API Error: \(message)")
                    #endif
                }

            default:
                #if DEBUG
                // Log unhandled events with their full JSON for debugging
                if let jsonData = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted),
                   let jsonStr = String(data: jsonData, encoding: .utf8) {
                    print("🎤 Unhandled Event: \(eventType)")
                    print("   JSON: \(jsonStr.prefix(500))")
                }
                #endif
            }
        }
    }

    // MARK: - Audio Recording
    func startRecording() {
        // Don't start new recording if waiting for previous transcription
        guard !isWaitingForTranscription else {
            #if DEBUG
            print("⏳ Still waiting for previous transcription, please wait...")
            #endif
            return
        }

        #if DEBUG
        print("🎤 startRecording() - checking permission...")
        print("   Current permissionStatus: \(permissionStatus.rawValue)")
        print("   0=notDetermined, 1=restricted, 2=denied, 3=authorized")
        #endif

        // Re-check permission status (in case user granted it externally)
        checkMicrophonePermission()
        
        guard permissionStatus == .authorized else {
            #if DEBUG
            print("⚠️ Microphone permission NOT authorized - requesting permission...")
            print("   Current status: \(permissionStatus.rawValue) (0=notDetermined, 1=restricted, 2=denied, 3=authorized)")
            #endif
            
            // If already denied, set error message
            if permissionStatus == .denied {
                errorMessage = "Microphone permission denied. Please enable it in System Settings > Privacy & Security > Microphone."
                #if DEBUG
                print("❌ Permission already denied - user needs to enable in System Settings")
                #endif
                return
            }
            
            requestMicrophonePermission { [weak self] granted in
                if granted {
                    #if DEBUG
                    print("✅ Permission granted! Retrying startRecording()...")
                    #endif
                    self?.startRecording()
                } else {
                    #if DEBUG
                    print("❌ Permission DENIED by user")
                    #endif
                    self?.errorMessage = "Microphone permission denied. Please enable it in System Settings > Privacy & Security > Microphone."
                }
            }
            return
        }

        guard isConnected else {
            #if DEBUG
            print("⚠️ Not connected - call toggleRecording() instead of startRecording() directly")
            #endif
            return
        }

        // BUFFERED MODE: Clear previous transcription for new recording
        transcribedText = ""

        #if DEBUG
        print("🎤 Permission authorized, setting up audio engine...")
        #endif

        setupAudioEngine()
    }

    func stopRecording() {
        // Stop audio capture
        audioEngine?.stop()
        inputNode?.removeTap(onBus: 0)
        audioEngine = nil
        audioConverter = nil
        isRecording = false

        // Mark that we're waiting for transcription
        isWaitingForTranscription = true
        isProcessing = true

        #if DEBUG
        print("🎤 Recording stopped. Processing buffered audio...")
        #endif

        // BUFFERED MODE: Now send all the accumulated audio at once
        sendBufferedAudioForTranscription()

        // Set a timeout in case transcription never arrives (15 seconds for longer recordings)
        transcriptionTimeout?.cancel()
        transcriptionTimeout = DispatchWorkItem { [weak self] in
            DispatchQueue.main.async {
                self?.isWaitingForTranscription = false
                self?.isProcessing = false
                #if DEBUG
                print("⚠️ Transcription timeout - no response received after 15 seconds")
                #endif
            }
        }

        // Longer timeout for buffered mode (complete recordings can take longer to process)
        if let timeout = transcriptionTimeout {
            DispatchQueue.main.asyncAfter(deadline: .now() + 15.0, execute: timeout)
        }
    }

    private func setupAudioEngine() {
        // BUFFERED MODE: Clear any previous recording buffer
        recordingBuffer.removeAll()

        audioEngine = AVAudioEngine()
        inputNode = audioEngine?.inputNode

        guard let inputNode = inputNode else {
            errorMessage = "Failed to get audio input node"
            #if DEBUG
            print("❌ Failed to get audio input node")
            #endif
            return
        }

        // CRITICAL FIX: On macOS, check if we're getting the correct input device
        #if os(macOS)
        #if DEBUG
        // Log the current audio unit to see what device is being used
        if let audioUnit = inputNode.audioUnit {
            var deviceID: AudioDeviceID = 0
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            let status = AudioUnitGetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &deviceID,
                &size
            )

            if status == noErr {
                print("🎤 Current audio device ID: \(deviceID)")

                // Get device name using proper CFString handling
                var propertyAddress = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyDeviceNameCFString,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
                var unmanagedName: Unmanaged<CFString>?
                let nameStatus = AudioObjectGetPropertyData(
                    deviceID,
                    &propertyAddress,
                    0,
                    nil,
                    &nameSize,
                    &unmanagedName
                )

                if nameStatus == noErr, let cfName = unmanagedName?.takeUnretainedValue() {
                    print("🎤 Using audio device: \(cfName as String)")
                } else {
                    print("⚠️ Could not get device name (status: \(nameStatus))")
                }
            } else {
                print("⚠️ Could not get current device ID (status: \(status))")
            }
        }
        #endif
        #endif

        // Get the native format of the input node
        let nativeFormat = inputNode.outputFormat(forBus: 0)

        #if DEBUG
        print("🎤 Audio input node obtained")
        print("   Native format: \(nativeFormat.sampleRate)Hz, \(nativeFormat.channelCount) channel(s)")
        #endif

        // Create and store target format (16-bit PCM at 24kHz mono)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: channelCount,
            interleaved: true
        ) else {
            errorMessage = "Failed to create target audio format"
            #if DEBUG
            print("❌ Failed to create target audio format")
            #endif
            return
        }

        self.targetAudioFormat = targetFormat

        #if DEBUG
        print("   Target format: \(targetFormat.sampleRate)Hz, \(targetFormat.channelCount) channel(s), PCM16")
        #endif

        // Create audio converter once for efficiency
        self.audioConverter = AVAudioConverter(from: nativeFormat, to: targetFormat)

        // Install tap using native format, then convert and BUFFER locally
        inputNode.installTap(onBus: 0, bufferSize: 2400, format: nativeFormat) { [weak self] buffer, _ in
            self?.bufferAudioLocally(buffer)
        }

        #if DEBUG
        print("   Audio tap installed with buffer size: 2400")
        #endif

        do {
            try audioEngine?.start()
            isRecording = true
            #if DEBUG
            print("✅ Audio engine started successfully!")
            print("🎤 Recording started (BUFFERED MODE - audio will be sent when you stop)")
            #endif
        } catch {
            errorMessage = "Failed to start audio engine: \(error.localizedDescription)"
        }
    }

    /// BUFFERED MODE: Accumulate audio locally instead of streaming
    private func bufferAudioLocally(_ buffer: AVAudioPCMBuffer) {
        // Update audio level for waveform visualization
        updateAudioLevel(from: buffer)

        guard let targetFormat = targetAudioFormat,
              let converter = audioConverter else {
            return
        }

        // Calculate frame capacity for converted buffer
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let frameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1

        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else {
            return
        }

        var error: NSError?
        var hasData = true
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if hasData {
                hasData = false
                outStatus.pointee = .haveData
                return buffer
            } else {
                outStatus.pointee = .noDataNow
                return nil
            }
        }

        let conversionStatus = converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)

        // Track if this is the first buffer for logging
        let isFirstBuffer = recordingBuffer.isEmpty

        #if DEBUG
        if isFirstBuffer {
            print("🎤 Audio Conversion Debug:")
            print("   Input buffer frameLength: \(buffer.frameLength)")
            print("   Input format: \(buffer.format.sampleRate)Hz, \(buffer.format.channelCount)ch")
            print("   Conversion status: \(conversionStatus.rawValue)")
            print("   Conversion error: \(error?.localizedDescription ?? "none")")
            print("   Output buffer frameLength: \(convertedBuffer.frameLength)")
            print("   Output format: \(convertedBuffer.format.sampleRate)Hz, \(convertedBuffer.format.channelCount)ch")
        }
        #endif

        if error == nil, let channelData = convertedBuffer.int16ChannelData {
            let frameLength = Int(convertedBuffer.frameLength)
            let data = Data(bytes: channelData[0], count: frameLength * 2)

            #if DEBUG
            // Check if we're getting actual audio data (not just silence)
            if isFirstBuffer {
                let firstSamples = channelData[0]
                var hasNonZero = false
                for i in 0..<min(100, Int(frameLength)) {
                    if firstSamples[i] != 0 {
                        hasNonZero = true
                        break
                    }
                }
                print("🎤 First converted buffer:")
                print("   Frame length: \(frameLength)")
                print("   Data size: \(data.count) bytes")
                print("   Has non-zero samples: \(hasNonZero ? "YES ✅" : "NO ❌ (SILENCE)")")
                if hasNonZero {
                    print("   First 10 samples: \(Array(UnsafeBufferPointer(start: firstSamples, count: min(10, Int(frameLength)))))")
                } else {
                    print("   ⚠️ ALL ZEROS - Conversion failed!")
                }
            }
            #endif

            // BUFFERED MODE: Accumulate audio data locally (don't send yet)
            recordingBuffer.append(data)
        } else {
            #if DEBUG
            if isFirstBuffer {
                print("❌ Failed to get converted audio data!")
                print("   Error: \(error?.localizedDescription ?? "none")")
                print("   channelData exists: \(convertedBuffer.int16ChannelData != nil)")
            }
            #endif
        }
    }

    /// Send the complete buffered audio to the API for transcription
    private func sendBufferedAudioForTranscription() {
        guard !recordingBuffer.isEmpty else {
            #if DEBUG
            print("⚠️ No audio recorded to transcribe")
            #endif
            isProcessing = false
            isWaitingForTranscription = false
            return
        }

        // CRITICAL: Verify WebSocket is connected before sending
        guard isConnected, webSocket != nil else {
            #if DEBUG
            print("❌ WebSocket not connected! Cannot send audio for transcription.")
            print("   isConnected: \(isConnected), webSocket: \(webSocket != nil ? "exists" : "nil")")
            #endif
            isProcessing = false
            isWaitingForTranscription = false
            errorMessage = "Voice connection lost. Please try again."
            return
        }

        #if DEBUG
        let durationSeconds = Double(recordingBuffer.count) / (sampleRate * 2.0) // 2 bytes per sample
        print("🎤 Sending \(recordingBuffer.count) bytes (~\(String(format: "%.1f", durationSeconds))s) for transcription...")
        print("   WebSocket state: connected=\(isConnected)")
        print("   Audio format: PCM16, \(sampleRate)Hz, \(channelCount) channel(s)")
        print("   First 20 bytes: \(recordingBuffer.prefix(20).map { String(format: "%02x", $0) }.joined(separator: " "))")
        #endif

        // Convert entire buffer to base64
        let base64Audio = recordingBuffer.base64EncodedString()

        // Send the complete audio buffer at once
        let audioEvent: [String: Any] = [
            "type": "input_audio_buffer.append",
            "audio": base64Audio
        ]
        sendJSON(audioEvent)

        // Commit the buffer to trigger transcription
        sendJSON(["type": "input_audio_buffer.commit"])

        // Request a response (this triggers the transcription)
        let responseRequest: [String: Any] = [
            "type": "response.create",
            "response": [
                "modalities": ["text"],  // We only want text transcription, not audio response
                "instructions": "Transcribe the audio accurately. Return only the transcribed text without any additions."
            ]
        ]
        sendJSON(responseRequest)

        #if DEBUG
        print("🎤 Complete audio sent, waiting for transcription...")
        print("   transcriptionVersion before response: \(transcriptionVersion)")
        #endif

        // Clear buffer after sending
        recordingBuffer.removeAll()
    }

    // MARK: - Toggle Recording
    func toggleRecording() {
        #if DEBUG
        print("🎤 toggleRecording() called - isRecording: \(isRecording), isConnecting: \(isConnecting), isConnected: \(isConnected)")
        #endif

        // Prevent multiple clicks while connecting
        if isConnecting {
            #if DEBUG
            print("⏳ Already connecting, ignoring click...")
            #endif
            return
        }

        // Prevent toggle while waiting for transcription
        if isWaitingForTranscription {
            #if DEBUG
            print("⏳ Waiting for transcription, ignoring click...")
            #endif
            return
        }

        if isRecording {
            stopRecording()
        } else {
            // Ensure connection before starting recording
            if !isConnected {
                isConnecting = true
                isProcessing = true  // Show visual feedback
                connect()

                #if DEBUG
                print("🎤 Connecting to voice API...")
                #endif

                // Poll for connection with timeout
                waitForConnectionAndStart(attempts: 0)
            } else {
                startRecording()
            }
        }
    }

    private func waitForConnectionAndStart(attempts: Int) {
        // Use faster polling initially, then back off
        // Attempts 0-2: 100ms (total 300ms)
        // Attempts 3-6: 200ms (total 800ms)
        // Attempts 7-10: 500ms (total 2s)
        let delay: TimeInterval
        if attempts < 3 {
            delay = 0.1  // Check every 100ms for first 300ms
        } else if attempts < 7 {
            delay = 0.2  // Then every 200ms for next 800ms
        } else {
            delay = 0.5  // Then every 500ms for final 2 seconds
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }

            // Check if user cancelled (clicked again while connecting)
            guard self.isConnecting else {
                #if DEBUG
                print("🎤 Connection attempt cancelled")
                #endif
                return
            }

            if self.isConnected {
                self.isConnecting = false
                self.isProcessing = false
                self.startRecording()
                #if DEBUG
                print("🎤 Connected after \(attempts) attempts! Starting recording...")
                #endif
            } else if attempts < 10 { // Try for ~3 seconds total
                self.waitForConnectionAndStart(attempts: attempts + 1)
            } else {
                self.isConnecting = false
                self.isProcessing = false
                self.errorMessage = "Failed to connect to voice API"
                #if DEBUG
                print("❌ Connection timeout after 3 seconds")
                #endif
            }
        }
    }

    // MARK: - Audio Level Monitoring (for waveform)
    private func updateAudioLevel(from buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }

        let channelDataValue = channelData.pointee
        let channelDataValueArray = stride(from: 0, to: Int(buffer.frameLength), by: buffer.stride).map { channelDataValue[$0] }

        let rms = sqrt(channelDataValueArray.map { $0 * $0 }.reduce(0, +) / Float(buffer.frameLength))
        let avgPower = 20 * log10(rms)
        let normalizedLevel = max(0.0, min(1.0, (avgPower + 50) / 50)) // Normalize -50dB to 0dB -> 0.0 to 1.0

        DispatchQueue.main.async { [weak self] in
            self?.audioLevel = normalizedLevel
        }
    }

    // MARK: - TTS Audio Playback
    private func appendAudioData(_ base64Audio: String) {
        guard let audioData = Data(base64Encoded: base64Audio) else {
            #if DEBUG
            print("🔊 Failed to decode base64 audio")
            #endif
            return
        }

        audioDataBuffer.append(audioData)
    }

    private func playAccumulatedAudio() {
        guard !audioDataBuffer.isEmpty else { return }

        // Convert PCM16 data to playable audio format
        let audioFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: channelCount,
            interleaved: true
        )

        guard let audioFormat = audioFormat else {
            #if DEBUG
            print("🔊 Failed to create audio format for playback")
            #endif
            return
        }

        // Create audio buffer from accumulated data
        let frameCount = audioDataBuffer.count / 2 // 16-bit = 2 bytes per sample
        guard let audioBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
            #if DEBUG
            print("🔊 Failed to create audio buffer")
            #endif
            return
        }

        audioBuffer.frameLength = AVAudioFrameCount(frameCount)

        // Copy data to buffer
        audioDataBuffer.withUnsafeBytes { rawBufferPointer in
            guard let baseAddress = rawBufferPointer.baseAddress else { return }
            audioBuffer.int16ChannelData?.pointee.update(from: baseAddress.assumingMemoryBound(to: Int16.self), count: frameCount)
        }

        // Play using AVAudioEngine for better control
        playAudioBuffer(audioBuffer, format: audioFormat)

        // Clear buffer
        audioDataBuffer.removeAll()
    }

    private func playAudioBuffer(_ buffer: AVAudioPCMBuffer, format: AVAudioFormat) {
        let audioEngine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()

        audioEngine.attach(playerNode)
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: format)

        do {
            try audioEngine.start()

            DispatchQueue.main.async { [weak self] in
                self?.isSpeaking = true
                self?.onSpeechStart?()
            }

            playerNode.scheduleBuffer(buffer) { [weak self] in
                DispatchQueue.main.async {
                    self?.isSpeaking = false
                    self?.onSpeechEnd?()
                    audioEngine.stop()
                }
            }

            playerNode.play()

            #if DEBUG
            print("🔊 Playing TTS audio (\(buffer.frameLength) frames)")
            #endif
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.errorMessage = "Failed to play audio: \(error.localizedDescription)"
                self?.isSpeaking = false
            }
            #if DEBUG
            print("🔊 Audio playback error: \(error)")
            #endif
        }
    }

    // MARK: - TTS Control
    func toggleTTS() {
        isTTSEnabled.toggle()
        #if DEBUG
        print("🔊 TTS \(isTTSEnabled ? "enabled" : "disabled")")
        #endif
    }

    func stopSpeaking() {
        audioPlayer?.stop()
        audioPlayerQueue?.pause()
        isSpeaking = false
        audioDataBuffer.removeAll()
    }

    // MARK: - Debug Test Function
    /// Test function to verify SwiftUI binding works
    /// Call this from the UI to test if transcriptionVersion changes trigger onChange
    func testTranscriptionBinding() {
        #if DEBUG
        print("🧪 TEST: Simulating transcription...")
        print("   Current transcriptionVersion: \(transcriptionVersion)")
        print("   Thread: \(Thread.isMainThread ? "MAIN" : "BACKGROUND")")
        #endif

        // Ensure we're on main thread
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            let testText = "Test transcription at \(Date().timeIntervalSince1970)"
            self.transcribedText = testText
            self.transcriptionVersion += 1

            #if DEBUG
            print("🧪 TEST: Set transcribedText to: '\(testText)'")
            print("🧪 TEST: Incremented transcriptionVersion to: \(self.transcriptionVersion)")
            print("🧪 TEST: If onChange doesn't fire, there's a SwiftUI binding issue")
            #endif
        }
    }
}

// MARK: - URLSessionWebSocketDelegate
extension VoiceManager: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        #if DEBUG
        print("🔌 URLSession delegate: didOpenWithProtocol called")
        print("   Thread: \(Thread.isMainThread ? "MAIN" : "BACKGROUND")")
        #endif

        DispatchQueue.main.async { [weak self] in
            #if DEBUG
            print("🔌 Setting isConnected = true")
            #endif
            self?.isConnected = true

            #if DEBUG
            print("✅ WebSocket connected successfully!")
            #endif

            // Send session configuration now that we're actually connected
            self?.sendSessionConfig()
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        #if DEBUG
        print("🔌 URLSession delegate: didCloseWith called")
        print("   closeCode: \(closeCode.rawValue)")
        if let reason = reason, let reasonStr = String(data: reason, encoding: .utf8) {
            print("   reason: \(reasonStr)")
        }
        #endif

        DispatchQueue.main.async { [weak self] in
            self?.isConnected = false
            self?.isRecording = false
            self?.isConnecting = false
            #if DEBUG
            print("❌ WebSocket disconnected")
            #endif
        }
    }
}
