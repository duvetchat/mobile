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

## Push notifications

The app gets its notifications through Firebase Cloud Messaging (`lib/push`): Firebase gives the phone an installation ID (FID), which the app hands the API, and the API sends it the messages that notify the user. The Firebase project's `android/app/google-services.json` is in the repo (it holds no secret), and the `com.google.gms.google-services` Gradle plugin reads it: Android builds need it. The background work (a push shown while the app isn't in front, the session's renewal) runs on Flutter engines of its own in the app's process, so `flutter_webrtc` comes from a fork that keeps one audio manager for all of them (`dependency_overrides` in `pubspec.yaml`): with the package as published, such an engine starting during a call took the call's audio output switching, and its release as the call ended.
