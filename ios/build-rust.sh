#!/usr/bin/env bash
# Сборка Rust-ядра для iOS. Запускать на Mac (Xcode не нужен — только rustup + command line tools).
# Кладёт в ios/libs/:
#   iphoneos/liblarp_core.a          — arm64 (настоящий iPhone)
#   iphonesimulator/liblarp_core.a   — fat (arm64 + x86_64) для симулятора на любом Mac
set -euo pipefail

cd "$(dirname "$0")/.."

rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios 2>/dev/null || true

for t in aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios; do
  echo "==> building larp-core for $t"
  cargo build --release -p larp-core --target "$t"
done

mkdir -p ios/libs/iphoneos ios/libs/iphonesimulator

# Устройство (телефон всегда arm64)
cp target/aarch64-apple-ios/release/liblarp_core.a ios/libs/iphoneos/

# Симулятор: сливаем arm64 (Apple Silicon) и x86_64 (Intel Mac) в одну fat-библиотеку
xcrun lipo -create \
  target/aarch64-apple-ios-sim/release/liblarp_core.a \
  target/x86_64-apple-ios/release/liblarp_core.a \
  -output ios/libs/iphonesimulator/liblarp_core.a

echo
echo "OK. libs:"
ls -la ios/libs/iphoneos/ ios/libs/iphonesimulator/
echo
echo "Теперь: xcodegen generate --spec ios/project.yml && open ios/LarpiOS.xcodeproj"