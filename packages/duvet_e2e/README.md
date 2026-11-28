# duvet_e2e, vendored

The end-to-end encryption core's Flutter plugin, as `tool/vendor_core.sh` copied it from commit `b7fc99e2254d28ff240bab1b293518f357b2f9b9` of
duvetchat/e2e: its Dart, for Android and iOS, with the libraries the core's CI built in place of cargokit, so the
app's builds compile no Rust. `android/src/main/jniLibs/arm64-v8a/libduvet_e2e.so` is Android's;
`ios/duvet_e2e/Frameworks/duvet_e2e.xcframework`, a phone's framework and a simulator's, is iOS's, which
`ios/duvet_e2e/Package.swift` hands to Xcode as a binary target; and `linux-x64/libduvet_e2e.so` is what the tests
load (`DUVET_E2E_LIB`). `SOURCE.json` has every file's SHA-256. Nothing here is edited by hand: run
`tool/vendor_core.sh <commit>` again.
