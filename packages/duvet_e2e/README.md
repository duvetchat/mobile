# duvet_e2e, vendored

The end-to-end encryption core's Flutter plugin, as `tool/vendor_core.sh` copied it from commit `d8642b5ab99ae0dbc0387b2e0759be977d480940` of
duvetchat/e2e, which is private: its Dart, for Android alone, with `android/src/main/jniLibs/arm64-v8a/libduvet_e2e.so`,
built by the core's CI, in place of cargokit, and `linux-x64/libduvet_e2e.so`, which the tests load
(`DUVET_E2E_LIB`). `SOURCE.json` has every file's SHA-256. Nothing here is edited by hand: run
`tool/vendor_core.sh <commit>` again.
