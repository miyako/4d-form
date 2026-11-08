#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.bareRepository GIT_CONFIG_VALUE_0=all
swift build -c release --product fourdform --triple arm64-apple-macosx12.0
swift build -c release --product fourdform --triple x86_64-apple-macosx12.0
mkdir -p dist
lipo -create .build/arm64-apple-macosx/release/fourdform \
  .build/x86_64-apple-macosx/release/fourdform -output dist/fourdform
codesign --force --sign - --identifier com.miyako.fourdform dist/fourdform
codesign --verify --strict dist/fourdform
lipo dist/fourdform -verify_arch arm64 x86_64
python3 scripts/smoke.py dist/fourdform
tar -cJf dist/fourdform-macos-universal.tar.xz -C dist fourdform
cp release.json dist/release.json
(cd dist && shasum -a 256 fourdform-macos-universal.tar.xz > SHA256SUMS)
