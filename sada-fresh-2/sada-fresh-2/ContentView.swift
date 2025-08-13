//
//  ContentView.swift
//  sada-fresh-2
//
//  Created by Mo on 13/08/2025.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var pitchDetector = PitchDetector()
    @StateObject private var audioManager: AudioCaptureManager
    @StateObject private var validationController: ValidationController
    @State private var showValidationView = false
    
    init() {
        let detector = PitchDetector()
        _pitchDetector = StateObject(wrappedValue: detector)
        _audioManager = StateObject(wrappedValue: AudioCaptureManager(pitchDetector: detector))
        _validationController = StateObject(wrappedValue: ValidationController(pitchDetector: detector))
    }
    
    var body: some View {
        NavigationView {
            VStack(spacing: 30) {
                // Header
                Text("Acapella PEP Monitor")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
                
                // Status Indicator
                HStack {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 12, height: 12)
                    Text(statusText)
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                
                // Main Display Cards
                VStack(spacing: 20) {
                    // Pitch Display
                    MetricCard(
                        title: "Detected Pitch",
                        value: String(format: "%.1f", pitchDetector.currentPitch),
                        unit: "Hz",
                        range: "Target: 10-40 Hz",
                        color: pitchColor,
                        isActive: pitchDetector.currentPitch > 0
                    )
                    
                    // Pressure Display
                    MetricCard(
                        title: "Estimated Pressure",
                        value: String(format: "%.1f", pitchDetector.currentPressure),
                        unit: "cmH₂O",
                        range: "Target: 10-20 cmH₂O",
                        color: pressureColor,
                        isActive: pitchDetector.currentPressure > 0
                    )
                    
                    // Run Length Indicator
                    HStack {
                        Text("Signal Quality:")
                        Spacer()
                        HStack(spacing: 4) {
                            ForEach(0..<5, id: \.self) { index in
                                Circle()
                                    .fill(index < pitchDetector.runLength ? .green : .gray.opacity(0.3))
                                    .frame(width: 12, height: 12)
                            }
                        }
                    }
                    .padding(.horizontal)
                }
                
                Spacer()
                
                // Usage Instructions
                VStack(alignment: .leading, spacing: 8) {
                    Text("Instructions:")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    Text("1. Hold your device close to the Acapella")
                    Text("2. Press Start and begin breathing exercises")
                    Text("3. Maintain steady 10-20 cmH₂O pressure")
                    Text("4. Watch for consistent green signal quality")
                }
                .font(.footnote)
                .foregroundColor(.secondary)
                .padding(.horizontal)
                
                Spacer()
                
                // Control Buttons
                VStack(spacing: 12) {
                    // Main Control Button
                    Button(action: {
                        if audioManager.isRecording {
                            audioManager.stopRecording()
                        } else {
                            if audioManager.hasPermission {
                                audioManager.startRecording()
                            } else {
                                audioManager.requestMicrophonePermission()
                            }
                        }
                    }) {
                        HStack {
                            Image(systemName: audioManager.isRecording ? "stop.fill" : "play.fill")
                            Text(audioManager.isRecording ? "Stop Monitoring" : 
                                 audioManager.hasPermission ? "Start Monitoring" : "Grant Microphone Access")
                        }
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(audioManager.isRecording ? .red : .blue)
                        .cornerRadius(12)
                    }
                    
                    // FDA Validation Button
                    Button(action: {
                        showValidationView = true
                    }) {
                        HStack {
                            Image(systemName: "checkmark.seal.fill")
                            Text("FDA Validation Suite")
                        }
                        .font(.subheadline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(.green)
                        .cornerRadius(8)
                    }
                }
                .padding(.horizontal)
            }
            .padding()
            .navigationBarHidden(true)
        }
        .onAppear {
            audioManager.requestMicrophonePermission()
        }
        .sheet(isPresented: $showValidationView) {
            ValidationView(controller: validationController)
        }
    }
    
    private var statusColor: Color {
        if audioManager.isRecording && pitchDetector.currentPitch > 0 {
            return .green
        } else if audioManager.isRecording {
            return .orange
        } else {
            return .gray
        }
    }
    
    private var statusText: String {
        if audioManager.isRecording && pitchDetector.currentPitch > 0 {
            return "Detecting Signal"
        } else if audioManager.isRecording {
            return "Listening..."
        } else {
            return "Inactive"
        }
    }
    
    private var pitchColor: Color {
        let pitch = pitchDetector.currentPitch
        if pitch >= 10 && pitch <= 40 {
            return .green
        } else if pitch > 0 {
            return .orange
        } else {
            return .gray
        }
    }
    
    private var pressureColor: Color {
        let pressure = pitchDetector.currentPressure
        if pressure >= 10 && pressure <= 20 {
            return .green
        } else if pressure > 0 {
            return .orange
        } else {
            return .gray
        }
    }
}

struct MetricCard: View {
    let title: String
    let value: String
    let unit: String
    let range: String
    let color: Color
    let isActive: Bool
    
    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundColor(.secondary)
            
            HStack(alignment: .bottom, spacing: 4) {
                Text(value)
                    .font(.system(size: 42, weight: .bold, design: .monospaced))
                    .foregroundColor(color)
                Text(unit)
                    .font(.title2)
                    .foregroundColor(.secondary)
                    .offset(y: -8)
            }
            
            Text(range)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(isActive ? color.opacity(0.3) : Color.clear, lineWidth: 2)
                )
        )
    }
}

#Preview {
    ContentView()
}
