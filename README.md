# duvet

A new Flutter project.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.

## Build flags

The app talks to production unless told otherwise at build time, with `--dart-define`:

| Name | Default | What |
|---|---|---|
| `DUVET_API` | `api.duvet.chat` | The REST API's host (and port), without a scheme |
| `DUVET_GATEWAY` | `ws.duvet.chat` | The gateway's host (and port), without a scheme |
| `DUVET_SECURE` | `true` | `false` reaches both over `http` and `ws` instead of `https` and `wss`, for a local server |

```bash
flutter run --dart-define=DUVET_API=192.168.1.20:8080 --dart-define=DUVET_GATEWAY=192.168.1.20:8081 --dart-define=DUVET_SECURE=false
```

Links to Duvet (`duvet.chat` invites and messages, and the `duvet://` ones) stay on the web domain whatever these say.

## iOS

The app builds for iOS on a Mac with Xcode. Its plugins come through Swift Package Manager, Flutter's default: the project has no Podfile, and CocoaPods isn't needed. A build for the simulator needs no signing:

```bash
flutter build ios --simulator --debug
```

CI's `ios` job builds it so on `macos-latest`, and fails when the build still changes `ios/` (a migration of a newer Flutter, or a plugin without a Swift package); its `ios-changes` artifact holds what Flutter wrote, to commit. A build for a phone needs an Apple team, which the project doesn't name yet.

The job then runs `integration_test/core_test.dart` in the app on an iPhone simulator: the end-to-end encryption core opens from the framework its vendored plugin brings (`packages/duvet_e2e/ios`), with no library handed to it. On a Mac whose Flutter has its iOS artifacts, with a simulator booted:

```bash
flutter test integration_test/core_test.dart -d <simulator>
```

## Push notifications

The app gets its notifications through Firebase Cloud Messaging (`lib/push`): Firebase gives the phone an installation ID (FID), which the app hands the API, and the API sends it the messages that notify the user. The Firebase project's `android/app/google-services.json` is in the repo (it holds no secret), and the `com.google.gms.google-services` Gradle plugin reads it: Android builds need it. The background work (a push shown while the app isn't in front, the session's renewal) runs on Flutter engines of its own in the app's process, so `flutter_webrtc` comes from a fork that keeps one audio manager for all of them (`dependency_overrides` in `pubspec.yaml`): with the package as published, such an engine starting during a call took the call's audio output switching, and its release as the call ended.
