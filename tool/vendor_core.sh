#!/usr/bin/env bash
# Vendors the end-to-end encryption core's Flutter plugin into packages/duvet_e2e (PLAN-E2E-CLIENTES.md, Ruling 3;
# PLAN-E2E-PLATAFORMAS.md, Task 12): the plugin's Dart at <commit> of duvetchat/e2e and the libraries its
# artifacts.yml built from that commit (the release artifacts-<7 digits>) live here, prebuilt and checksummed, so
# neither the app's builds nor its CI compile Rust. Android's arm64-v8a library takes cargokit's place in Gradle's
# build; iOS's XCFramework, a phone's framework and a simulator's, is a Swift package's binary target, which Xcode
# links and embeds in the app; Linux's library is what the tests load (DUVET_E2E_LIB). gh reads the repository and
# the release. Each download is checked against the release's SHA256SUMS before anything is written, and
# packages/duvet_e2e/SOURCE.json records the commit and every file's SHA-256, which test/e2e/vendored_core_test.dart
# checks.
#
#   tool/vendor_core.sh <commit>
set -euo pipefail

repository=duvetchat/e2e
commit=${1:-}
if [[ ! $commit =~ ^[0-9a-f]{7,40}$ ]]; then
  echo "usage: tool/vendor_core.sh <commit>" >&2
  exit 2
fi
root=$(cd "$(dirname "$0")/.." && pwd)
package=packages/duvet_e2e
tag=artifacts-${commit:0:7}

# The whole commit the release was built from: a short one can grow ambiguous.
built=$(gh release view "$tag" --repo "$repository" --json targetCommitish --jq .targetCommitish)
if [[ ! $built =~ ^[0-9a-f]{40}$ || $built != "$commit"* ]]; then
  echo "$tag was built from $built, not $commit" >&2
  exit 1
fi

cache=$HOME/.cache/duvet-core/${commit:0:7}
mkdir -p "$cache"
gh release download "$tag" --repo "$repository" --dir "$cache" --clobber --pattern SHA256SUMS \
  --pattern android-arm64-v8a-libduvet_e2e.so --pattern libduvet_e2e.so --pattern ios-duvet_e2e.xcframework.zip
for name in android-arm64-v8a-libduvet_e2e.so libduvet_e2e.so ios-duvet_e2e.xcframework.zip; do
  listed=$(awk -v name="$name" '$2 == name || $2 == "*" name { print $1 }' "$cache/SHA256SUMS")
  actual=$(sha256sum "$cache/$name" | cut -d' ' -f1)
  if [[ -z $listed || $listed != "$actual" ]]; then
    echo "$name has the SHA-256 $actual, where SHA256SUMS says ${listed:-nothing}" >&2
    exit 1
  fi
done

# The new folder is made whole apart, then takes the old one's place (below): a failure until then leaves the
# repository as it was.
next=$(mktemp -d)
chmod 755 "$next"
trap 'rm -rf "$next"' EXIT
plugin() {
  mkdir -p "$next/$(dirname "$1")"
  gh api -H 'Accept: application/vnd.github.raw+json' \
    "repos/$repository/contents/flutter/duvet_e2e/$1?ref=$built" >"$next/$1"
}
for file in lib/duvet_e2e.dart lib/src/rust/api/core.dart lib/src/rust/frb_generated.dart \
  lib/src/rust/frb_generated.io.dart lib/src/rust/frb_generated.web.dart \
  android/settings.gradle android/src/main/AndroidManifest.xml pubspec.yaml android/build.gradle; do
  plugin "$file"
done

# The plugin for Android and iOS, the platforms the app carries the core's libraries for: cargokit, which built them
# all, isn't here.
sed -i '/^flutter:$/,$d' "$next/pubspec.yaml"
cat >>"$next/pubspec.yaml" <<'YAML'
flutter:
  plugin:
    platforms:
      android:
        ffiPlugin: true
      ios:
        ffiPlugin: true
YAML
# Its library is in src/main/jniLibs, which the Android Gradle Plugin packages as it is: cargokit's build goes.
sed -i '/cargokit\/gradle\/plugin.gradle/,$d' "$next/android/build.gradle"
if grep -q cargokit "$next/android/build.gradle"; then
  echo "the plugin's build.gradle changed shape: check what tool/vendor_core.sh cuts from it" >&2
  exit 1
fi
mkdir -p "$next/android/src/main/jniLibs/arm64-v8a" "$next/linux-x64" "$next/ios/duvet_e2e/Frameworks"
cp "$cache/android-arm64-v8a-libduvet_e2e.so" "$next/android/src/main/jniLibs/arm64-v8a/libduvet_e2e.so"
cp "$cache/libduvet_e2e.so" "$next/linux-x64/libduvet_e2e.so"
# The XCFramework, whose every entry must be inside it: nothing the archive names lands elsewhere.
stray=$(unzip -Z1 "$cache/ios-duvet_e2e.xcframework.zip" | awk '!/^duvet_e2e\.xcframework\// || /(^|\/)\.\.(\/|$)/')
if [[ -n $stray ]]; then
  echo "ios-duvet_e2e.xcframework.zip holds more than duvet_e2e.xcframework/: $stray" >&2
  exit 1
fi
unzip -q "$cache/ios-duvet_e2e.xcframework.zip" -d "$next/ios/duvet_e2e/Frameworks"
# Flutter adds a plugin's Swift package to the app by the product name it gives it (the plugin's name with hyphens).
# Its one target is the framework, so nothing compiles: Xcode links and embeds it, and flutter_rust_bridge opens it
# by its name (duvet_e2e.framework/duvet_e2e). 13.0 is the framework's own minimum.
cat >"$next/ios/duvet_e2e/Package.swift" <<'SWIFT'
// swift-tools-version: 5.9
// Written by tool/vendor_core.sh: the core's framework for iOS, which its CI built, as a binary target.

import PackageDescription

let package = Package(
    name: "duvet_e2e",
    platforms: [
        .iOS("13.0")
    ],
    products: [
        .library(name: "duvet-e2e", targets: ["duvet_e2e"])
    ],
    targets: [
        .binaryTarget(name: "duvet_e2e", path: "Frameworks/duvet_e2e.xcframework")
    ]
)
SWIFT
cat >"$next/README.md" <<EOF
# duvet_e2e, vendored

The end-to-end encryption core's Flutter plugin, as \`tool/vendor_core.sh\` copied it from commit \`$built\` of
duvetchat/e2e: its Dart, for Android and iOS, with the libraries the core's CI built in place of cargokit, so the
app's builds compile no Rust. \`android/src/main/jniLibs/arm64-v8a/libduvet_e2e.so\` is Android's;
\`ios/duvet_e2e/Frameworks/duvet_e2e.xcframework\`, a phone's framework and a simulator's, is iOS's, which
\`ios/duvet_e2e/Package.swift\` hands to Xcode as a binary target; and \`linux-x64/libduvet_e2e.so\` is what the tests
load (\`DUVET_E2E_LIB\`). \`SOURCE.json\` has every file's SHA-256. Nothing here is edited by hand: run
\`tool/vendor_core.sh <commit>\` again.
EOF

(
  cd "$next"
  echo '{'
  echo "  \"repository\": \"$repository\","
  echo "  \"commit\": \"$built\","
  echo '  "files": {'
  find . -type f | sed 's|^\./||' | LC_ALL=C sort | while read -r file; do
    echo "    \"$package/$file\": \"$(sha256sum "$file" | cut -d' ' -f1)\""
  done | sed '$!s/$/,/'
  echo '  }'
  echo '}'
) >"$cache/SOURCE.json"
mv "$cache/SOURCE.json" "$next/SOURCE.json"

# Copied beside the package, then renamed into its place: a copy that fails midway (a full disk) leaves the package as
# it was. Only an end between the two renames would leave it aside, in packages/.duvet_e2e.old.
staged=$root/packages/.duvet_e2e.next
old=$root/packages/.duvet_e2e.old
trap 'rm -rf "$next" "$staged"' EXIT
mkdir -p "$root/packages"
rm -rf "$staged" "$old"
cp -R "$next" "$staged"
if [[ -e $root/$package ]]; then mv "$root/$package" "$old"; fi
if ! mv "$staged" "$root/$package"; then
  if [[ -e $old ]]; then mv "$old" "$root/$package"; fi
  exit 1
fi
rm -rf "$old"
echo "The core's plugin of $built is in $package."
