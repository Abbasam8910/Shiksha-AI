<p align="center">
  <h1 align="center">📚 Mobileshiksha</h1>
  <p align="center">
    <strong>Offline AI Tutor for Android</strong><br>
    A privacy-first educational assistant powered by on-device LLM inference
  </p>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Flutter-3.22+-blue?logo=flutter" alt="Flutter">
  <img src="https://img.shields.io/badge/Dart-3.4+-0175C2?logo=dart" alt="Dart">
  <img src="https://img.shields.io/badge/Platform-Android-green?logo=android" alt="Platform">
  <img src="https://img.shields.io/badge/License-MIT-yellow" alt="License">
</p>

---

## ✨ Features

- **100% Offline** — No internet required after initial model download
- **Privacy-First** — All inference happens locally; your data never leaves the device
- **Device-Aware** — Automatically adapts to your phone's RAM and battery level
- **Real-Time Streaming** — Token-by-token response generation with live UI updates
- **Markdown Support** — AI responses render with formatting, lists, and code blocks
- **Persistent History** — Chat sessions saved locally with automatic smart titles

---

## 📱 Screenshots

> *Coming soon*

---

## 🚀 Getting Started

### Prerequisites

- [Flutter SDK](https://docs.flutter.dev/get-started/install) 3.22 or higher
- Android device or emulator (API 21+)
- ~2GB free storage for the model file

### Installation

1. **Clone the repository**
   ```bash
   git clone https://github.com/yourusername/shiksha_v1.git
   cd shiksha_v1
   ```

2. **Install dependencies**
   ```bash
   flutter pub get
   ```

3. **Run on device**
   ```bash
   flutter run
   ```

4. **Download the model**  
   On first launch, the app will prompt you to download the quantized LLM (~1.5GB).

---

## 🏗️ Architecture

```
lib/
├── main.dart              # Entry point, native library loading
├── models/                # Data models (ChatMessage, ChatSession)
├── providers/             # Riverpod state management
├── screens/               # UI screens (Chat, Onboarding, Download)
└── services/              # Business logic
    ├── llm_service.dart           # LLM inference engine
    ├── device_config_service.dart # Hardware profiling
    └── model_download_service.dart
```

### Key Components

| Component | Description |
|-----------|-------------|
| `LLMService` | Manages model loading, token streaming, and context |
| `DeviceConfigService` | Profiles RAM/battery and selects optimal config |
| `ChatProvider` | State management for messages and sessions |

---

## ⚙️ Device Tiers

The app automatically selects configuration based on available resources:

| Tier | RAM | Context Size | Max Tokens | Mode |
|------|-----|--------------|------------|------|
| Efficiency | < 5 GB | 2048 | 256 | CPU Only |
| Balanced | 5–7 GB | 2048 | 384 | CPU Only |
| Performance | ≥ 7 GB | 4096 | 512 | GPU Accelerated |

> Battery protection: If battery < 20%, the app forces Efficiency mode.

---

## 🛠️ Tech Stack

- **Framework**: [Flutter](https://flutter.dev) + [Dart](https://dart.dev)
- **State Management**: [Riverpod](https://riverpod.dev)
- **Local Storage**: [Hive](https://docs.hivedb.dev)
- **LLM Engine**: [llama.cpp](https://github.com/ggerganov/llama.cpp) via `llama_cpp_dart`
- **Model**: Qwen 4-bit quantized (LoRA fine-tuned)

---

## 📖 Documentation

- [Project Overview](./docs/overview.md) — Architecture, state diagrams, and flows

---

## 🤝 Contributing

Contributions are welcome! Please read our contributing guidelines before submitting a PR.

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

---

## 📄 License

This project is licensed under the MIT License — see the [LICENSE](LICENSE) file for details.

---

## 🙏 Acknowledgments

- [llama.cpp](https://github.com/ggerganov/llama.cpp) for efficient LLM inference
- [Flutter](https://flutter.dev) for the cross-platform framework
- The open-source community for inspiration and support

---

