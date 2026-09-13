#!/usr/bin/env bash
# Сборка Rust-ядра для iOS. Запускать на Mac (Xcode не нужен — нужен только rustup).
# Кладёт liblarp_core.a в ios/libs/{iphoneos,iphonesimulator}.
set -euo pipefail

cd "$(dirname "$0")/.."

rustup target add aarch64-apple-ios aarch64-apple-ios-sim 2>/dev/null || true

for t in aarch64-apple-ios aarch64-apple-ios-sim; do
  echo "==> building larp-core for $t"
  cargo build --release -p larp-core --target "$t"
done

mkdir -p ios/libs/iphoneos ios/libs/iphonesimulator
cp target/aarch64-apple-ios/release/liblarp_core.a ios/libs/iphoneos/
cp target/aarch64-apple-ios-sim/release/liblarp_core.a ios/libs/iphonesimulator/

echo
echo "OK. libs:"
ls -la ios/libs/iphoneos/ ios/libs/iphonesimulator/
echo
echo "Теперь: xcodegen generate --spec ios/project.yml && open ios/LarpiOS.xcodeproj"