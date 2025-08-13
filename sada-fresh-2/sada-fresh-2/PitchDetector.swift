import Foundation
import AVFoundation
import Accelerate

class PitchDetector: ObservableObject {
    // Algorithm parameters from the research paper (Appendix A)
    private let sampleRate: Float = 44100.0
    private let minFreq: Float = 10.0
    private let maxFreq: Float = 40.0
    private let freqAccuracy: Float = 0.025
    private let lowerFormantFreq: Float = 250.0
    private let decayRate: Float = 0.8
    private let minAmp: Float = 2.0E-4
    private let downsampleFactor: Int = 45
    private let minCorrelation: Float = 0.6
    
    // Incremental processing parameters (0.1-0.2ms as per spec)
    private let incrementalChunkDuration: Float = 0.0002 // 0.2ms
    private let incrementalChunkSize: Int
    
    // Performance benchmarking
    private var processingTimes: [TimeInterval] = []
    private var benchmarkStartTime: Date?
    private var totalAudioProcessed: TimeInterval = 0
    
    @Published var currentPitch: Float = 0.0
    @Published var currentPressure: Float = 0.0
    @Published var isProcessing: Bool = false
    @Published var runLength: Int = 0
    
    // Moving averages for pitch tracking
    private var movingAvePeriod: Float = 0.0
    private var movingAveAmplitude: Float = 0.0
    private var movingAveDerivative: Float = 0.0
    private var lastDetectedPitch: Float = 0.0
    private var pitchRunLength: Int = 0
    private let maxRunLength: Int = 5 // round(1 - 1/0.8)
    
    // Audio processing buffers and synchronization
    private var audioBuffer: [Float] = []
    private var processedSamples: Int = 0
    private let gaussianSigma: Float
    private var audioEnergyBuffer: [Float] = []
    
    // Pressure/Audio synchronization (as per research paper methods)
    private var audioEnergyHistory: [(timestamp: TimeInterval, energy: Float)] = []
    private var pressureHistory: [(timestamp: TimeInterval, pressure: Float)] = []
    private var timeRegistrationOffset: TimeInterval = 0.0
    private let maxHistoryDuration: TimeInterval = 30.0 // Keep 30 seconds of history
    
    // Economical autocorrelation optimization
    private var lastAutocorrelationLag: Int = 0
    private var searchWindowCenter: Int = 0
    private var searchWindowSize: Int = 10
    
    init() {
        // Calculate Gaussian sigma for smoothing (as per Appendix A)
        gaussianSigma = 0.2 * Float(downsampleFactor) * maxFreq / sampleRate
        
        // Calculate incremental chunk size
        incrementalChunkSize = Int(sampleRate * incrementalChunkDuration)
        
        resetSession()
    }
    
    func resetSession() {
        movingAvePeriod = 0.0
        movingAveAmplitude = 0.0
        movingAveDerivative = 0.0
        lastDetectedPitch = 0.0
        pitchRunLength = 0
        processedSamples = 0
        audioBuffer.removeAll()
        audioEnergyBuffer.removeAll()
        
        // Reset synchronization data
        audioEnergyHistory.removeAll()
        pressureHistory.removeAll()
        timeRegistrationOffset = 0.0
        
        // Reset autocorrelation optimization
        lastAutocorrelationLag = 0
        searchWindowCenter = 0
        
        // Reset performance benchmarking
        processingTimes.removeAll()
        benchmarkStartTime = Date()
        totalAudioProcessed = 0
        
        DispatchQueue.main.async {
            self.currentPitch = 0.0
            self.currentPressure = 0.0
            self.runLength = 0
        }
    }
    
    func processAudioChunk(_ audioData: [Float]) -> Float {
        let startTime = Date()
        
        // Performance benchmarking: track audio duration processed
        let audioDuration = Double(audioData.count) / Double(sampleRate)
        totalAudioProcessed += audioDuration
        
        // Step 1: Subtract smoothed version from raw audio (Appendix A, step 3)
        let smoothedAudio = computeSmoothedSignal(audioData)
        var subtractedSignal = [Float](repeating: 0.0, count: audioData.count)
        vDSP_vsub(smoothedAudio, 1, audioData, 1, &subtractedSignal, 1, vDSP_Length(audioData.count))
        
        // Step 2: Compute square of the signal (Appendix A, step 4)
        var squaredSignal = [Float](repeating: 0.0, count: subtractedSignal.count)
        vDSP_vsq(subtractedSignal, 1, &squaredSignal, 1, vDSP_Length(subtractedSignal.count))
        
        // Step 3: Downsample by averaging contiguous sets of 45 samples (Appendix A, step 5)
        let downsampledSignal = downsampleSignal(squaredSignal)
        
        // Step 4: Apply Gaussian smoothing (Appendix A, step 6)
        let smoothedEnergySignal = applyGaussianSmoothing(downsampledSignal)
        
        // Store audio energy for synchronization (as per research paper methods)
        let audioEnergy = computeAudioEnergy(smoothedEnergySignal)
        let timestamp = Date().timeIntervalSince1970
        addAudioEnergyPoint(timestamp: timestamp, energy: audioEnergy)
        
        // Step 5: Compute economical autocorrelation and detect pitch (Appendix A, steps 8-9)
        let detectedPitch = detectPitchFromAutocorrelationOptimized(smoothedEnergySignal)
        
        // Step 6: Update moving averages and compute final pitch (Appendix A, steps 10-12)
        updateMovingAverages(detectedPitch)
        
        let finalPitch = computeFinalPitch()
        let pressure = computePressureFromPitchResearchDerived(finalPitch)
        
        // Performance benchmarking
        let processingTime = Date().timeIntervalSince(startTime)
        processingTimes.append(processingTime)
        validatePerformanceRequirements()
        
        // Real-time display logic: only update UI with latest readings
        DispatchQueue.main.async {
            self.currentPitch = finalPitch
            self.currentPressure = pressure
            self.runLength = self.pitchRunLength
        }
        
        return finalPitch
    }
    
    private func computeSmoothedSignal(_ signal: [Float]) -> [Float] {
        // Average over neighborhood equal to smallest formant frequency (176 samples)
        let windowSize = Int(sampleRate / lowerFormantFreq)
        var smoothed = [Float](repeating: 0.0, count: signal.count)
        
        for i in 0..<signal.count {
            let start = max(0, i - windowSize/2)
            let end = min(signal.count - 1, i + windowSize/2)
            var sum: Float = 0.0
            
            for j in start...end {
                sum += signal[j]
            }
            smoothed[i] = sum / Float(end - start + 1)
        }
        
        return smoothed
    }
    
    private func downsampleSignal(_ signal: [Float]) -> [Float] {
        let outputSize = signal.count / downsampleFactor
        var downsampled = [Float](repeating: 0.0, count: outputSize)
        
        for i in 0..<outputSize {
            var sum: Float = 0.0
            let startIdx = i * downsampleFactor
            let endIdx = min(startIdx + downsampleFactor, signal.count)
            
            for j in startIdx..<endIdx {
                sum += signal[j]
            }
            downsampled[i] = sum / Float(endIdx - startIdx)
        }
        
        return downsampled
    }
    
    private func applyGaussianSmoothing(_ signal: [Float]) -> [Float] {
        // Fine-tuned Gaussian smoothing as per Appendix A, step 6
        // FWHM = 0.4 times the period of the highest pitch frequency (40Hz)
        // This prevents blurring out the pitch signature in the upper range
        
        let optimizedSigma = gaussianSigma * 1.1 // Fine-tuning for better performance
        let kernelSize = max(3, Int(optimizedSigma * 6.0)) // Ensure minimum kernel size
        let halfKernel = kernelSize / 2
        var kernel = [Float](repeating: 0.0, count: kernelSize)
        
        var sum: Float = 0.0
        for i in 0..<kernelSize {
            let x = Float(i - halfKernel)
            let value = exp(-(x * x) / (2.0 * optimizedSigma * optimizedSigma))
            kernel[i] = value
            sum += value
        }
        
        // Normalize kernel to preserve signal energy
        for i in 0..<kernelSize {
            kernel[i] /= sum
        }
        
        // Apply convolution with boundary handling
        var smoothed = [Float](repeating: 0.0, count: signal.count)
        for i in 0..<signal.count {
            var convSum: Float = 0.0
            var kernelSum: Float = 0.0
            
            for j in 0..<kernelSize {
                let signalIdx = i + j - halfKernel
                if signalIdx >= 0 && signalIdx < signal.count {
                    convSum += signal[signalIdx] * kernel[j]
                    kernelSum += kernel[j]
                }
            }
            
            // Normalize by actual kernel sum to handle boundaries correctly
            smoothed[i] = kernelSum > 0 ? convSum / kernelSum : 0.0
        }
        
        return smoothed
    }
    
    private func detectPitchFromAutocorrelation(_ signal: [Float]) -> Float {
        guard signal.count > 0 else { return 0.0 }
        
        let downsampledRate = sampleRate / Float(downsampleFactor)
        let minPeriod = Int(downsampledRate / maxFreq)
        let maxPeriod = Int(downsampledRate / minFreq)
        
        guard maxPeriod < signal.count else { return 0.0 }
        
        var maxCorrelation: Float = 0.0
        var bestLag: Int = 0
        
        // Compute autocorrelation for each lag
        for lag in minPeriod...maxPeriod {
            var correlation: Float = 0.0
            var norm1: Float = 0.0
            var norm2: Float = 0.0
            
            for i in 0..<(signal.count - lag) {
                let val1 = signal[i]
                let val2 = signal[i + lag]
                correlation += val1 * val2
                norm1 += val1 * val1
                norm2 += val2 * val2
            }
            
            let normalizedCorr = correlation / sqrt(norm1 * norm2)
            
            if normalizedCorr > maxCorrelation {
                maxCorrelation = normalizedCorr
                bestLag = lag
            }
        }
        
        // Only accept correlation above threshold
        if maxCorrelation > minCorrelation {
            let pitch = downsampledRate / Float(bestLag)
            return pitch
        }
        
        return 0.0
    }
    
    private func updateMovingAverages(_ detectedPitch: Float) {
        guard detectedPitch > 0.0 else {
            // No valid pitch detected
            pitchRunLength = max(0, pitchRunLength - 1)
            return
        }
        
        // Check if pitch leap is reasonable
        if lastDetectedPitch > 0.0 {
            let pitchRatio = detectedPitch / lastDetectedPitch
            if pitchRatio < 0.5 || pitchRatio > 2.0 {
                // Large leap detected, reduce run length
                pitchRunLength = max(0, pitchRunLength - 2)
                return
            }
        }
        
        // Valid pitch detected, increment run length
        pitchRunLength = min(pitchRunLength + 1, maxRunLength)
        
        // Update moving averages
        let mix = min(decayRate, 1.0 - 1.0/Float(max(pitchRunLength, 1)))
        let newPeriod = 1.0 / detectedPitch
        
        movingAvePeriod = movingAvePeriod * mix + newPeriod * (1.0 - mix)
        movingAveAmplitude = movingAveAmplitude * mix + detectedPitch * (1.0 - mix)
        
        lastDetectedPitch = detectedPitch
    }
    
    private func computeFinalPitch() -> Float {
        guard movingAvePeriod > 0.0 && pitchRunLength > 0 else { return 0.0 }
        return 1.0 / movingAvePeriod
    }
    
    // MARK: - Pressure/Audio Synchronization (Research Paper Methods Section)
    
    private func addAudioEnergyPoint(timestamp: TimeInterval, energy: Float) {
        audioEnergyHistory.append((timestamp: timestamp, energy: energy))
        
        // Clean old data beyond maxHistoryDuration
        let cutoffTime = timestamp - maxHistoryDuration
        audioEnergyHistory = audioEnergyHistory.filter { $0.timestamp > cutoffTime }
    }
    
    func addPressureReading(pressure: Float, timestamp: TimeInterval = Date().timeIntervalSince1970) {
        pressureHistory.append((timestamp: timestamp, pressure: pressure))
        
        // Clean old data beyond maxHistoryDuration
        let cutoffTime = timestamp - maxHistoryDuration
        pressureHistory = pressureHistory.filter { $0.timestamp > cutoffTime }
        
        // Perform time registration correlation if we have enough data
        if audioEnergyHistory.count > 100 && pressureHistory.count > 100 {
            updateTimeRegistration()
        }
    }
    
    private func updateTimeRegistration() {
        // Correlate pressure with square root of audio energy (as per paper)
        _ = audioEnergyHistory.map { sqrt($0.energy) }
        _ = pressureHistory.map { $0.pressure }
        
        var maxCorrelation: Float = -1.0
        var bestOffset: TimeInterval = 0.0
        
        // Search for best time alignment within ±5 seconds
        let searchRange: TimeInterval = 5.0
        let step: TimeInterval = 0.01 // 10ms steps
        
        for offsetMs in stride(from: -searchRange, through: searchRange, by: step) {
            let correlation = computeTimeOffsetCorrelation(offset: offsetMs)
            if correlation > maxCorrelation {
                maxCorrelation = correlation
                bestOffset = offsetMs
            }
        }
        
        if maxCorrelation > 0.3 { // Reasonable correlation threshold
            timeRegistrationOffset = bestOffset
        }
    }
    
    private func computeTimeOffsetCorrelation(offset: TimeInterval) -> Float {
        // Simplified correlation computation for time registration
        var correlation: Float = 0.0
        var count = 0
        
        for audioPoint in audioEnergyHistory {
            let adjustedTime = audioPoint.timestamp + offset
            
            // Find closest pressure reading
            if let closestPressure = pressureHistory.min(by: { abs($0.timestamp - adjustedTime) < abs($1.timestamp - adjustedTime) }) {
                let timeDiff = abs(closestPressure.timestamp - adjustedTime)
                if timeDiff < 0.1 { // Within 100ms
                    correlation += sqrt(audioPoint.energy) * closestPressure.pressure
                    count += 1
                }
            }
        }
        
        return count > 0 ? correlation / Float(count) : 0.0
    }
    
    private func computeAudioEnergy(_ signal: [Float]) -> Float {
        var energy: Float = 0.0
        vDSP_sve(signal, 1, &energy, vDSP_Length(signal.count))
        return energy / Float(signal.count)
    }
    
    // MARK: - Economical Autocorrelation (Appendix A, steps 8-9)
    
    private func detectPitchFromAutocorrelationOptimized(_ signal: [Float]) -> Float {
        guard signal.count > 0 else { return 0.0 }
        
        let downsampledRate = sampleRate / Float(downsampleFactor)
        let minPeriod = Int(downsampledRate / maxFreq)
        let maxPeriod = Int(downsampledRate / minFreq)
        
        guard maxPeriod < signal.count else { return 0.0 }
        
        var searchStart = minPeriod
        var searchEnd = maxPeriod
        
        // Economical optimization: focus search around last detection
        if lastAutocorrelationLag > 0 {
            let wavelength = lastAutocorrelationLag
            searchWindowCenter = wavelength // One wavelength ahead as per spec
            searchStart = max(minPeriod, searchWindowCenter - searchWindowSize)
            searchEnd = min(maxPeriod, searchWindowCenter + searchWindowSize)
        }
        
        var maxCorrelation: Float = 0.0
        var bestLag: Int = 0
        var correlations: [(lag: Int, correlation: Float)] = []
        
        // Rough resolution first
        let roughStep = max(1, (searchEnd - searchStart) / 20)
        for lag in stride(from: searchStart, through: searchEnd, by: roughStep) {
            let correlation = computeNormalizedAutocorrelation(signal, lag: lag)
            correlations.append((lag: lag, correlation: correlation))
            
            if correlation > maxCorrelation {
                maxCorrelation = correlation
                bestLag = lag
            }
        }
        
        // Fine resolution around maxima (as per spec step 9)
        if maxCorrelation > minCorrelation {
            let fineStart = max(searchStart, bestLag - roughStep)
            let fineEnd = min(searchEnd, bestLag + roughStep)
            
            for lag in fineStart...fineEnd {
                let correlation = computeNormalizedAutocorrelation(signal, lag: lag)
                if correlation > maxCorrelation {
                    maxCorrelation = correlation
                    bestLag = lag
                }
            }
        }
        
        // Update search window for next iteration
        if maxCorrelation > minCorrelation {
            lastAutocorrelationLag = bestLag
            searchWindowCenter = bestLag
            
            let pitch = downsampledRate / Float(bestLag)
            return pitch
        }
        
        return 0.0
    }
    
    private func computeNormalizedAutocorrelation(_ signal: [Float], lag: Int) -> Float {
        var correlation: Float = 0.0
        var norm1: Float = 0.0
        var norm2: Float = 0.0
        
        for i in 0..<(signal.count - lag) {
            let val1 = signal[i]
            let val2 = signal[i + lag]
            correlation += val1 * val2
            norm1 += val1 * val1
            norm2 += val2 * val2
        }
        
        let denominator = sqrt(norm1 * norm2)
        return denominator > 0 ? correlation / denominator : 0.0
    }
    
    // MARK: - Research-Derived Pressure Model (Figure 4 data)
    
    private func computePressureFromPitchResearchDerived(_ pitch: Float) -> Float {
        // Linear model from research paper Figure 4: r² = 0.886
        // Based on actual data points from 9,993 measurements across 19 diverse subjects
        // Linear regression from the research data: P = 0.68 * f - 1.2 (approximate from graph)
        let slope: Float = 0.68  // cmH2O per Hz (derived from Figure 4)
        let intercept: Float = -1.2  // cmH2O offset (derived from Figure 4)
        
        guard pitch >= minFreq && pitch <= maxFreq else { return 0.0 }
        
        let pressure = slope * pitch + intercept
        return max(0.0, pressure)
    }
    
    // MARK: - Performance Benchmarking (Research Paper: 50ms/20s requirement)
    
    private func validatePerformanceRequirements() {
        guard let startTime = benchmarkStartTime else { return }
        
        let currentTime = Date()
        
        // Check if we've processed 20 seconds of audio (benchmark requirement)
        if totalAudioProcessed >= 20.0 {
            let totalProcessingTime = processingTimes.reduce(0, +)
            let performanceRatio = totalProcessingTime / totalAudioProcessed
            
            print("Performance Benchmark Results:")
            print("Audio processed: \(totalAudioProcessed)s")
            print("Processing time: \(totalProcessingTime * 1000)ms")
            print("Performance ratio: \(performanceRatio * 1000)ms per second of audio")
            print("Target: <50ms per 20s (2.5ms per second)")
            print("Status: \(performanceRatio < 0.0025 ? "✅ PASSED" : "❌ FAILED")")
            
            // Reset for next benchmark cycle
            processingTimes.removeAll()
            benchmarkStartTime = Date()
            totalAudioProcessed = 0
        }
    }
    
    // MARK: - Memory Leak Testing Framework
    
    func performMemoryLeakTest(iterations: Int = 1000, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let startMemory = self.getCurrentMemoryUsage()
            
            for i in 0..<iterations {
                // Simulate typical processing load
                let testAudioData = Array(repeating: Float.random(in: -1...1), count: 4096)
                _ = self.processAudioChunk(testAudioData)
                
                if i % 100 == 0 {
                    // Force garbage collection
                    autoreleasepool {
                        // Empty pool to release temporary objects
                    }
                }
            }
            
            let endMemory = self.getCurrentMemoryUsage()
            let memoryIncrease = endMemory - startMemory
            let memoryLeakThreshold: UInt64 = 50 * 1024 * 1024 // 50MB threshold
            
            let passed = memoryIncrease < memoryLeakThreshold
            
            print("Memory Leak Test Results:")
            print("Start memory: \(startMemory / 1024 / 1024)MB")
            print("End memory: \(endMemory / 1024 / 1024)MB")
            print("Memory increase: \(memoryIncrease / 1024 / 1024)MB")
            print("Status: \(passed ? "✅ PASSED" : "❌ FAILED - Potential memory leak")")
            
            DispatchQueue.main.async {
                completion(passed)
            }
        }
    }
    
    private func getCurrentMemoryUsage() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4
        
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_,
                         task_flavor_t(MACH_TASK_BASIC_INFO),
                         $0,
                         &count)
            }
        }
        
        if kerr == KERN_SUCCESS {
            return info.resident_size
        } else {
            return 0
        }
    }
    
    // MARK: - Legacy Methods (kept for compatibility)
    
    
    
    private func computePressureFromPitch(_ pitch: Float) -> Float {
        // Fallback to research-derived version
        return computePressureFromPitchResearchDerived(pitch)
    }
}
