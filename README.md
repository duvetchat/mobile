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
