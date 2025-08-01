#!/usr/bin/env bash
set -euf -o pipefail
ONNX_CONFIG="${1:-model.required_operators_and_types.config}"
CMAKE_BUILD_TYPE=MinSizeRel

build_arch() {
  ONNX_CONFIG="$1"
  ARCH="$2"
  python onnxruntime/tools/ci_build/build.py \
  --build_dir "onnxruntime/build/macOS_${ARCH}" \
  --config=${CMAKE_BUILD_TYPE} \
  --parallel \
  --minimal_build \
  --apple_deploy_target="10.13" \
  --disable_ml_ops --disable_rtti \
  --include_ops_by_config "$ONNX_CONFIG" \
  --enable_reduced_operator_type_support \
  --cmake_extra_defines CMAKE_OSX_ARCHITECTURES="${ARCH}" \
  --skip_tests
  
  BUILD_DIR=./onnxruntime/build/macOS_${ARCH}/${CMAKE_BUILD_TYPE}
  
  # DEBUG: Show all available libraries
  echo "=== Available libraries for ${ARCH} ==="
  find "$BUILD_DIR" -name "*.a" -exec echo "Found: {}" \;
  
  # Check if critical libonnx.a exists and contains the symbol
  if [ -f "${BUILD_DIR}/libonnx.a" ]; then
    echo "✅ libonnx.a found for ${ARCH}"
    if nm "${BUILD_DIR}/libonnx.a" | grep -q "propagateElemTypeFromInputToOutput"; then
      echo "✅ Critical symbol found in libonnx.a for ${ARCH}"
    else
      echo "❌ Critical symbol NOT found in libonnx.a for ${ARCH}"
    fi
  else
    echo "❌ libonnx.a NOT found for ${ARCH}!"
  fi
  
  # Build the combined library with ALL necessary components
  echo "=== Building combined library for ${ARCH} ==="
  
  # Core ONNX Runtime libraries (always needed)
  CORE_LIBS=(
    "${BUILD_DIR}/libonnxruntime_graph.a"
    "${BUILD_DIR}/libonnxruntime_common.a" 
    "${BUILD_DIR}/libonnxruntime_providers.a"
    "${BUILD_DIR}/libonnxruntime_session.a"
    "${BUILD_DIR}/libonnxruntime_flatbuffers.a"
    "${BUILD_DIR}/libonnxruntime_framework.a"
    "${BUILD_DIR}/libonnxruntime_util.a"
    "${BUILD_DIR}/libonnxruntime_mlas.a"
    "${BUILD_DIR}/libonnxruntime_optimizer.a"
  )
  
  # ONNX libraries (CRITICAL - these contain the missing symbols!)
  ONNX_LIBS=(
    "${BUILD_DIR}/libonnx.a"
    "${BUILD_DIR}/libonnx_proto.a"
  )
  
  # Test and optional libraries
  OPTIONAL_LIBS=(
    "${BUILD_DIR}/libonnx_test_data_proto.a"
    "${BUILD_DIR}/libonnx_test_runner_common.a"
    "${BUILD_DIR}/libonnxruntime_test_utils.a"
  )
  
  # Dependency libraries
  DEPENDENCY_LIBS=(
    "${BUILD_DIR}/_deps/re2-build/libre2.a"
    "${BUILD_DIR}/_deps/google_nsync-build/libnsync_cpp.a"
    "${BUILD_DIR}/_deps/protobuf-build/libprotobuf-lite.a"
    "${BUILD_DIR}/_deps/abseil_cpp-build/absl/hash/libabsl_hash.a"
    "${BUILD_DIR}/_deps/abseil_cpp-build/absl/hash/libabsl_city.a"
    "${BUILD_DIR}/_deps/abseil_cpp-build/absl/hash/libabsl_low_level_hash.a"
    "${BUILD_DIR}/_deps/abseil_cpp-build/absl/base/libabsl_throw_delegate.a"
    "${BUILD_DIR}/_deps/abseil_cpp-build/absl/container/libabsl_raw_hash_set.a"
    "${BUILD_DIR}/_deps/abseil_cpp-build/absl/base/libabsl_raw_logging_internal.a"
  )
  
  # Collect all existing libraries
  ALL_LIBS=()
  
  # Add core libraries (must exist)
  for lib in "${CORE_LIBS[@]}"; do
    if [ -f "$lib" ]; then
      ALL_LIBS+=("$lib")
      echo "✅ Added core: $(basename "$lib")"
    else
      echo "❌ Missing core library: $lib"
    fi
  done
  
  # Add ONNX libraries (CRITICAL!)
  for lib in "${ONNX_LIBS[@]}"; do
    if [ -f "$lib" ]; then
      ALL_LIBS+=("$lib")
      echo "✅ Added ONNX: $(basename "$lib")"
    else
      echo "❌ Missing ONNX library: $lib"
    fi
  done
  
  # Add optional libraries if they exist
  for lib in "${OPTIONAL_LIBS[@]}"; do
    if [ -f "$lib" ]; then
      ALL_LIBS+=("$lib")
      echo "✅ Added optional: $(basename "$lib")"
    else
      echo "⚠️  Optional library not found: $(basename "$lib")"
    fi
  done
  
  # Add dependency libraries if they exist
  for lib in "${DEPENDENCY_LIBS[@]}"; do
    if [ -f "$lib" ]; then
      ALL_LIBS+=("$lib")
      echo "✅ Added dependency: $(basename "$lib")"
    else
      echo "⚠️  Dependency library not found: $(basename "$lib")"
    fi
  done
  
  # Create the combined library
  echo "=== Creating combined library with ${#ALL_LIBS[@]} components ==="
  libtool -static -o "onnxruntime-macOS_${ARCH}-static-combined.a" "${ALL_LIBS[@]}"
  
  # Verify the combined library contains the critical symbol
  if nm "onnxruntime-macOS_${ARCH}-static-combined.a" | grep -q "propagateElemTypeFromInputToOutput"; then
    echo "✅ Combined library for ${ARCH} contains critical symbol!"
  else
    echo "❌ Combined library for ${ARCH} MISSING critical symbol!"
    echo "Checking individual ONNX libraries:"
    for lib in "${ONNX_LIBS[@]}"; do
      if [ -f "$lib" ]; then
        echo "Checking $lib:"
        nm "$lib" | grep "propagateElemTypeFromInputToOutput" || echo "  Not found in $(basename "$lib")"
      fi
    done
  fi
}

# Build both architectures
build_arch "$ONNX_CONFIG" x86_64
build_arch "$ONNX_CONFIG" arm64

# Create universal binary
mkdir -p libs/macos-arm64_x86_64
echo "=== Creating Universal Binary ==="
lipo -create onnxruntime-macOS_x86_64-static-combined.a \
             onnxruntime-macOS_arm64-static-combined.a \
     -output "libs/macos-arm64_x86_64/libonnxruntime.a"

# Final verification
echo "=== Final Universal Binary Verification ==="
lipo -info "libs/macos-arm64_x86_64/libonnxruntime.a"

# Test the critical symbol in the universal binary
if nm "libs/macos-arm64_x86_64/libonnxruntime.a" | grep -q "propagateElemTypeFromInputToOutput"; then
  echo "✅ Universal binary contains critical symbol!"
else
  echo "❌ Universal binary MISSING critical symbol!"
  
  # Test individual architectures
  lipo -extract arm64 "libs/macos-arm64_x86_64/libonnxruntime.a" -output /tmp/test_arm64.a
  lipo -extract x86_64 "libs/macos-arm64_x86_64/libonnxruntime.a" -output /tmp/test_x86_64.a
  
  echo "ARM64 arch symbol check:"
  nm /tmp/test_arm64.a | grep "propagateElemTypeFromInputToOutput" || echo "  Not in ARM64"
  echo "x86_64 arch symbol check:"  
  nm /tmp/test_x86_64.a | grep "propagateElemTypeFromInputToOutput" || echo "  Not in x86_64"
  
  rm -f /tmp/test_arm64.a /tmp/test_x86_64.a
fi

# Clean up intermediate files
rm onnxruntime-macOS_x86_64-static-combined.a
rm onnxruntime-macOS_arm64-static-combined.a

echo "=== Build Complete ==="
