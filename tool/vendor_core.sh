#!/usr/bin/env bash
# Vendors the end-to-end encryption core's Flutter plugin into packages/duvet_e2e (PLAN-E2E-CLIENTES.md, Ruling 3):
# the app's CI can't read the core's private repository, so the plugin's Dart at <commit> of duvetchat/e2e and the
# two libraries its artifacts.yml built from that commit (the release artifacts-<7 digits>) live here. Android's
# arm64-v8a library takes cargokit's place, so neither the app's Gradle build nor its CI compiles Rust; Linux's is
# what the tests load (DUVET_E2E_LIB). gh reads the repository and the release with its own session. Both libraries
# are checked against the release's SHA256SUMS before anything is written, and packages/duvet_e2e/SOURCE.json
# records the commit and every file's SHA-256, which test/e2e/vendored_core_test.dart checks.
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
gh release download "$tag" --repo "$repository" --dir "$cache" --clobber \
  --pattern SHA256SUMS --pattern android-arm64-v8a-libduvet_e2e.so --pattern libduvet_e2e.so
for name in android-arm64-v8a-libduvet_e2e.so libduvet_e2e.so; do
  listed=$(awk -v name="$name" '$2 == name || $2 == "*" name { print $1 }' "$cache/SHA256SUMS")
  actual=$(sha256sum "$cache/$name" | cut -d' ' -f1)
  if [[ -z $listed || $listed != "$actual" ]]; then
    echo "$name has the SHA-256 $actual, where SHA256SUMS says ${listed:-nothing}" >&2
    exit 1
  fi
done

# The new folder is made whole apart, then takes the old one's place: a failure leaves the repository as it was.
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

# The plugin for Android alone: the app builds for no other platform with it, and cargokit, which built them all,
# isn't here.
sed -i '/^flutter:$/,$d' "$next/pubspec.yaml"
cat >>"$next/pubspec.yaml" <<'YAML'
flutter:
  plugin:
    platforms:
      android:
        ffiPlugin: true
YAML
# Its library is in src/main/jniLibs, which the Android Gradle Plugin packages as it is: cargokit's build goes.
sed -i '/cargokit\/gradle\/plugin.gradle/,$d' "$next/android/build.gradle"
if grep -q cargokit "$next/android/build.gradle"; then
  echo "the plugin's build.gradle changed shape: check what tool/vendor_core.sh cuts from it" >&2
  exit 1
fi
mkdir -p "$next/android/src/main/jniLibs/arm64-v8a" "$next/linux-x64"
cp "$cache/android-arm64-v8a-libduvet_e2e.so" "$next/android/src/main/jniLibs/arm64-v8a/libduvet_e2e.so"
cp "$cache/libduvet_e2e.so" "$next/linux-x64/libduvet_e2e.so"
cat >"$next/README.md" <<EOF
# duvet_e2e, vendored

The end-to-end encryption core's Flutter plugin, as \`tool/vendor_core.sh\` copied it from commit \`$built\` of
duvetchat/e2e, which is private: its Dart, for Android alone, with \`android/src/main/jniLibs/arm64-v8a/libduvet_e2e.so\`,
built by the core's CI, in place of cargokit, and \`linux-x64/libduvet_e2e.so\`, which the tests load
(\`DUVET_E2E_LIB\`). \`SOURCE.json\` has every file's SHA-256. Nothing here is edited by hand: run
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

rm -rf "${root:?}/$package"
mkdir -p "$root/packages"
cp -R "$next" "$root/$package"
echo "The core's plugin of $built is in $package."
