#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Antigravity-Proxy macOS 构建脚本
# 支持 Apple Silicon (M1/M2/M3/M4, arm64) 与 Intel (x86_64)
# ==============================================================================

BUILD_TYPE="${1:-Release}"
BUILD_DIR="build-mac"
OUTPUT_DIR="output-mac"
# 默认按当前架构构建，若需 Universal 2 通用二进制可设置环境变量: ARCHS="arm64;x86_64"
ARCHS="${ARCHS:-$(uname -m)}"

echo "=========================================="
echo " Antigravity-Proxy macOS Build"
echo " Build Type:   ${BUILD_TYPE}"
echo " Architecture: ${ARCHS}"
echo "=========================================="

# 创建构建目录
mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

# 生成构建文件
cmake .. \
    -DCMAKE_BUILD_TYPE="${BUILD_TYPE}" \
    -DCMAKE_OSX_ARCHITECTURES="${ARCHS}" \
    -DBUILD_TESTS=ON

# 编译
NPROC=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
cmake --build . --config "${BUILD_TYPE}" -j "${NPROC}"

# 运行单元测试
echo ""
echo ">> 正在执行单元测试套件..."
ctest --output-on-failure -C "${BUILD_TYPE}"

cd ..

# 整理产物到 output-mac
mkdir -p "${OUTPUT_DIR}"
cp "${BUILD_DIR}/libantigravity_proxy.dylib" "${OUTPUT_DIR}/"

if [ -f "config.example.json" ]; then
    cp "config.example.json" "${OUTPUT_DIR}/"
fi
if [ -f "config.json" ]; then
    cp "config.json" "${OUTPUT_DIR}/"
fi

echo ""
echo "=========================================="
echo " 构建成功！"
echo " 产物目录: ${OUTPUT_DIR}/"
echo " 核心动态库: ${OUTPUT_DIR}/libantigravity_proxy.dylib"
file "${OUTPUT_DIR}/libantigravity_proxy.dylib" 2>/dev/null || true
echo "=========================================="
