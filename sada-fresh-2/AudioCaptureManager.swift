import Foundation
import AVFoundation
import UIKit

class AudioCaptureManager: NSObject, ObservableObject {
    private var audioEngine = AVAudioEngine()
    private var inputNode: AVAudioInputNode!
    private var pitchDetector: PitchDetector
    
    @Published var isRecording = false
    @Published var hasPermission = false
    
    private let bufferSize: Int = 4096 // 0.1 seconds at 44.1kHz
    private var audioFormat: AVAudioFormat!
    
    init(pitchDetector: PitchDetector) {
        self.pitchDetector = pitchDetector
        super.init()
        setupAudioSession()
        setupAudioEngine()
    }
    
    private func setupAudioSession() {
        let audioSession = AVAudioSession.sharedInstance()
        
        do {
            try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetooth])
            try audioSession.setPreferredSampleRate(44100.0)
            try audioSession.setPreferredIOBufferDuration(0.1) // 100ms buffer
            try audioSession.setActive(true)
        } catch {
            print("Failed to setup audio session: \(error)")
        }
    }
    
    private func setupAudioEngine() {
        inputNode = audioEngine.inputNode
        audioFormat = inputNode.outputFormat(forBus: 0)
        
        // Install tap on input node to capture audio
        inputNode.installTap(onBus: 0, bufferSize: AVAudioFrameCount(bufferSize), format: audioFormat) { [weak self] buffer, time in
            self?.processAudioBuffer(buffer)
        }
        
        audioEngine.prepare()
    }
    
    func requestMicrophonePermission() {
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                self?.hasPermission = granted
                if !granted {
                    print("Microphone permission denied")
                }
            }
        }
    }
    
    func startRecording() {
        guard hasPermission else {
            requestMicrophonePermission()
            return
        }
        
        do {
            pitchDetector.resetSession()
            try audioEngine.start()
            DispatchQueue.main.async {
                self.isRecording = true
                self.pitchDetector.isProcessing = true
            }
        } catch {
            print("Failed to start audio engine: \(error)")
        }
    }
    
    func stopRecording() {
        audioEngine.stop()
        inputNode.removeTap(onBus: 0)
        
        DispatchQueue.main.async {
            self.isRecording = false
            self.pitchDetector.isProcessing = false
        }
        
        // Reinstall tap for next recording session
        setupAudioEngine()
    }
    
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        
        // Use only the first channel (mono)
        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
        
        // Process the audio chunk through pitch detector
        let detectedPitch = pitchDetector.processAudioChunk(samples)
        
        // Debug output (can be removed in production)
        if detectedPitch > 0 {
            print("Detected pitch: \(detectedPitch) Hz, Estimated pressure: \(pitchDetector.currentPressure) cmH2O")
        }
    }
    
    deinit {
        if audioEngine.isRunning {
            stopRecording()
        }
    }
}

// MARK: - Audio Session Management
extension AudioCaptureManager {
    func handleInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }
        
        switch type {
        case .began:
            if isRecording {
                stopRecording()
            }
        case .ended:
            guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            if options.contains(.shouldResume) {
                // Restart recording if it was active before interruption
            }
        @unknown default:
            break
        }
    }
    
    func handleRouteChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }
        
        switch reason {
        case .newDeviceAvailable, .oldDeviceUnavailable:
            // Handle device changes if needed
            if isRecording {
                stopRecording()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.startRecording()
                }
            }
        default:
            break
        }
    }
}
