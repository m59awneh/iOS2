import SwiftUI

struct ValidationView: View {
    @ObservedObject var controller: ValidationController
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    Text("FDA Validation Suite")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    
                    Text("Comprehensive testing as per research specification")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    Text("Paper: Auto-determination of proper usage of Acapella by detecting pitch in audio input")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .italic()
                }
                .padding(.horizontal)
                
                // Test Status Cards
                if controller.performancePassed != nil || controller.memoryLeakPassed != nil {
                    LazyVGrid(columns: [
                        GridItem(.flexible()),
                        GridItem(.flexible())
                    ], spacing: 16) {
                        TestStatusCard(
                            title: "Performance",
                            subtitle: "50ms/20s target",
                            status: controller.performancePassed,
                            icon: "speedometer"
                        )
                        
                        TestStatusCard(
                            title: "Memory",
                            subtitle: "Leak detection",
                            status: controller.memoryLeakPassed,
                            icon: "memorychip.fill"
                        )
                    }
                    .padding(.horizontal)
                }
                
                // Test Results Console
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(controller.testResults, id: \.self) { result in
                            Text(result)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                        }
                    }
                    .padding(.vertical)
                }
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(.systemGray6))
                )
                .padding(.horizontal)
                
                Spacer()
                
                // Control Buttons
                VStack(spacing: 12) {
                    Button(action: {
                        controller.runFDAValidationSuite()
                    }) {
                        HStack {
                            if controller.isRunningTests {
                                ProgressView()
                                    .scaleEffect(0.8)
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            } else {
                                Image(systemName: "play.circle.fill")
                            }
                            Text(controller.isRunningTests ? "Running Tests..." : "Run FDA Validation")
                        }
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(controller.isRunningTests ? .gray : .blue)
                        .cornerRadius(12)
                    }
                    .disabled(controller.isRunningTests)
                    
                    Button("Close") {
                        dismiss()
                    }
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                }
                .padding(.horizontal)
            }
            .padding(.vertical)
            .navigationBarHidden(true)
        }
    }
}

struct TestStatusCard: View {
    let title: String
    let subtitle: String
    let status: Bool?
    let icon: String
    
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(statusColor)
            
            VStack(spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundColor(.primary)
                
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Text(statusText)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(statusColor)
        }
        .padding()
        .frame(maxWidth: .infinity, minHeight: 120)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(statusColor.opacity(0.3), lineWidth: 2)
                )
        )
    }
    
    private var statusColor: Color {
        guard let status = status else { return .gray }
        return status ? .green : .red
    }
    
    private var statusText: String {
        guard let status = status else { return "Not Run" }
        return status ? "✅ PASSED" : "❌ FAILED"
    }
}

#Preview {
    ValidationView(controller: ValidationController(pitchDetector: PitchDetector()))
}
