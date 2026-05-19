#!/bin/bash
set -e

# Сборка Rust backend
cd battery-thresholdd
cargo build --release
cd ..

# Создание архива расширения
EXTENSION_UUID="battery-threshold@Korrnals.dev"
VERSION=$(grep -oP '"version": \K[0-9]+' metadata.json)
DIST_DIR="dist/$EXTENSION_UUID-v$VERSION"

mkdir -p "$DIST_DIR"

# Копирование файлов расширения
cp -r *.js *.json *.css *.xml *.md *.policy *.service "$DIST_DIR/"
cp -r schemas "$DIST_DIR/"

# Копирование Xiaomi-specific файлов
cp XIAOMI_SETUP.md "$DIST_DIR/"

# Копирование скомпилированного backend
mkdir -p "$DIST_DIR/battery-thresholdd"
cp battery-thresholdd/target/release/battery-thresholdd "$DIST_DIR/battery-thresholdd/"
cp battery-thresholdd/battery-threshold.service "$DIST_DIR/battery-thresholdd/"
cp battery-thresholdd/battery-threshold-xiaomi.service "$DIST_DIR/battery-thresholdd/"

# Создание ZIP-архива
cd dist
zip -r "$EXTENSION_UUID-v$VERSION.zip" "$EXTENSION_UUID-v$VERSION"
cd ..

echo "Extension built: dist/$EXTENSION_UUID-v$VERSION.zip"