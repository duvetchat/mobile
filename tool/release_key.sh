#!/usr/bin/env bash
# Writes android/key.properties, with which Gradle signs release builds with the release key
# (android/app/build.gradle.kts; without the file, the debug key): the one place that knows how the APK is signed, for
# ci.yml and release.yml. Takes the keystore in base64 and its passwords (KEYSTORE, STORE_PASSWORD, KEY_PASSWORD: the
# repository's secrets) and puts the keystore in the job's temporary folder (RUNNER_TEMP), which the runner empties as
# each job ends.
#
#   KEYSTORE=… STORE_PASSWORD=… KEY_PASSWORD=… tool/release_key.sh
set -euo pipefail

if [[ -z ${KEYSTORE:-} ]]; then
  echo "::error::no release key: ANDROID_KEYSTORE_BASE64 isn't set" >&2
  exit 1
fi
cd "$(dirname "$0")/../android"
echo "$KEYSTORE" | base64 --decode > "$RUNNER_TEMP/release.jks"
# A properties file reads \ as an escape: each one doubled stays itself.
{
  echo "storeFile=$RUNNER_TEMP/release.jks"
  echo "storePassword=${STORE_PASSWORD//\\/\\\\}"
  echo "keyAlias=duvet"
  echo "keyPassword=${KEY_PASSWORD//\\/\\\\}"
} > key.properties
