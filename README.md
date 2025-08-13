# Acapella PEP Pitch Detector

A real-time iOS app that monitors Acapella PEP (Positive Expiratory Pressure) therapy device usage through advanced pitch detection and audio signal processing.

## Overview

This app implements the research-validated algorithm from "Auto-determination of proper usage of Acapella by detecting pitch in audio input" by Sondre Skatter (Smiths Group Digital Forge, 2017). 

The algorithm achieves:
- **High correlation (r² = 0.886)** between detected pitch and internal pressure
- **Real-time processing** with 400x performance margin
- **Robust detection** across diverse patient populations and device settings

## Key Features

- **Real-time pitch detection** using autocorrelation algorithm (10-40 Hz range)
- **Pressure estimation** from linear model: Pressure = 0.6 × Pitch + 4.0 cmH₂O
- **Signal quality indicators** with 5-level run length tracking
- **Minimal UI** optimized for testing and validation
- **Audio processing pipeline** with downsampling and Gaussian smoothing

## Technical Implementation

### Algorithm Details
- **Target frequency range**: 10-40 Hz with 2.5% accuracy
- **Audio processing**: 44.1kHz → 980Hz downsampling (45x factor)
- **Autocorrelation threshold**: 0.6 minimum correlation
- **Moving averages**: Exponential decay (rate: 0.8) for pitch stability
- **Performance**: Processes 20s audio in ~50ms (400x real-time)

### Architecture
- **PitchDetector**: Core algorithm implementation with autocorrelation
- **AudioCaptureManager**: AVAudioEngine integration for real-time capture
- **ContentView**: SwiftUI interface with real-time feedback
- **Signal Processing**: Gaussian smoothing, energy computation, pitch tracking

## Usage

1. **Grant microphone permissions** when prompted
2. **Position iPhone near Acapella device** (no specific placement required)
3. **Press "Start Monitoring"** to begin real-time analysis
4. **Begin PEP therapy** with proper exhalation technique
5. **Monitor feedback**:
   - Green signal quality dots indicate stable detection
   - Target: 10-40 Hz pitch → 10-20 cmH₂O pressure
   - Consistent readings validate proper device usage

## Research Validation

Based on study with 19 diverse participants:
- 73 sessions with varying resistance settings (1-5)
- Multiple exhalation patterns and pressure sweeps  
- Consistent correlation across all demographics and settings
- Validates single universal model for all users/settings

## Performance Specifications

- **Latency**: ~100ms buffer for real-time feedback
- **Accuracy**: 2.5% pitch detection accuracy in target range
- **Robustness**: Functions with ambient room placement (no close positioning required)
- **Efficiency**: Designed for mobile deployment with significant performance headroom

## Development Notes

This is a research prototype focused on validating the core pitch detection algorithm. The minimal UI allows for:
- Algorithm validation against research benchmarks
- Performance testing on mobile hardware
- Real-world usage pattern analysis
- Identification of needed refinements before full app development

The implementation closely follows the research paper's specifications to ensure scientific accuracy and reproducible results.
