#!/usr/bin/env bash
set -euf -o pipefail
ONNX_CONFIG="${1:-model.required_operators_and_types.config}"
CMAKE_BUILD_TYPE=MinSizeRel

build_arch() {
  ONNX_CONFIG="$1"
  ARCH="$2"
  
  # Force cross-compilation settings for x86_64 on ARM64 host
  if [ "$ARCH" = "x86_64" ]; then
    echo "=== Configuring x86_64 cross-compilation on ARM64 host ==="
    export CC="clang -arch x86_64"
    export CXX="clang++ -arch x86_64"
    CROSS_COMPILE_FLAGS="--cmake_extra_defines CMAKE_OSX_ARCHITECTURES=x86_64 --cmake_extra_defines CMAKE_SYSTEM_PROCESSOR=x86_64"
  else
    echo "=== Configuring native ARM64 compilation ==="
    unset CC CXX
    CROSS_COMPILE_FLAGS="--cmake_extra_defines CMAKE_OSX_ARCHITECTURES=arm64"
  fi
  
  echo "Building for architecture: $ARCH"
  
  python onnxruntime/tools/ci_build/build.py \
  --build_dir "onnxruntime/build/macOS_${ARCH}" \
  --config=${CMAKE_BUILD_TYPE} \
  --parallel \
  --minimal_build \
  --apple_deploy_target="10.13" \
  --disable_ml_ops --disable_rtti \
  --include_ops_by_config "$ONNX_CONFIG" \
  --enable_reduced_operator_type_support \
  $CROSS_COMPILE_FLAGS \
  --skip_tests
  
  BUILD_DIR=./onnxruntime/build/macOS_${ARCH}/${CMAKE_BUILD_TYPE}
  
  # Verify the architecture was built correctly
  echo "=== Architecture Verification ==="
  if [ -f "${BUILD_DIR}/libonnxruntime_common.a" ]; then
    ACTUAL_ARCH=$(lipo -info "${BUILD_DIR}/libonnxruntime_common.a" | grep -o "arm64\|x86_64" || echo "unknown")
    echo "Expected: $ARCH, Actual: $ACTUAL_ARCH"
    if [ "$ACTUAL_ARCH" != "$ARCH" ]; then
      echo "❌ ERROR: Built $ACTUAL_ARCH instead of requested $ARCH"
      echo "This will cause lipo to fail later"
    else
      echo "✅ Architecture verification passed"
    fi
  fi
  
  # Look for ONNX libraries more thoroughly
  echo "=== ONNX Library Discovery ==="
  
  # Check multiple possible locations for ONNX libraries
  POSSIBLE_ONNX_LOCATIONS=(
    "${BUILD_DIR}"
    "${BUILD_DIR}/_deps/onnx-build"
    "${BUILD_DIR}/external/onnx"
    "${BUILD_DIR}/_deps/onnx-build/onnx"
    "$(find "${BUILD_DIR}" -type d -name "*onnx*" 2>/dev/null | head -1)"
  )
  
  FOUND_ONNX_LIBS=()
  
  for location in "${POSSIBLE_ONNX_LOCATIONS[@]}"; do
    if [ -n "$location" ] && [ -d "$location" ]; then
      echo "Checking location: $location"
      for lib in "$location"/libonnx*.a; do
        if [ -f "$lib" ]; then
          echo "✅ Found ONNX library: $lib"
          FOUND_ONNX_LIBS+=("$lib")
          
          # Check if this library defines the critical symbol
          if nm "$lib" 2>/dev/null | grep -E "^[0-9a-fA-F]+ [TtDd] .*propagateElemTypeFromInputToOutput"; then
            echo "  🎯 This library DEFINES the critical symbol!"
          else
            echo "  ❌ This library does NOT define the critical symbol"
          fi
        fi
      done
    fi
  done
  
  if [ ${#FOUND_ONNX_LIBS[@]} -eq 0 ]; then
    echo "❌ CRITICAL ERROR: No ONNX libraries found!"
    echo "This means ONNX was not built or is in an unexpected location"
    echo "Available .a files in build directory:"
    find "$BUILD_DIR" -name "*.a" -type f | head -20
    echo "Searching for any files containing 'onnx':"
    find "$BUILD_DIR" -name "*onnx*" -type f | head -10
    echo ""
    echo "This build will likely fail to provide the required symbols"
  fi
  
  # Get ALL .a files for combination
  echo "=== Collecting All Libraries ==="
  ALL_LIBS=($(find "$BUILD_DIR" -name "*.a" -type f | grep -v test | sort))
  
  echo "Found ${#ALL_LIBS[@]} libraries to combine"
  
  if [ ${#ALL_LIBS[@]} -eq 0 ]; then
    echo "❌ ERROR: No libraries found to combine!"
    exit 1
  fi
  
  # Create combined library
  echo "=== Creating Combined Library ==="
  libtool -static -o "onnxruntime-macOS_${ARCH}-static-combined.a" "${ALL_LIBS[@]}"
  
  # Verify architecture of combined library
  COMBINED_ARCH=$(lipo -info "onnxruntime-macOS_${ARCH}-static-combined.a" | grep -o "arm64\|x86_64" || echo "unknown")
  echo "Combined library architecture: $COMBINED_ARCH"
  
  # Final symbol check
  echo "=== Symbol Status Check ==="
  if nm "onnxruntime-macOS_${ARCH}-static-combined.a" 2>/dev/null | grep -E "^[0-9a-fA-F]+ [TtDd] .*propagateElemTypeFromInputToOutput"; then
    echo "🎉 SUCCESS: Critical symbol is DEFINED in $ARCH library"
  elif nm "onnxruntime-macOS_${ARCH}-static-combined.a" 2>/dev/null | grep -E "^[ ]*U .*propagateElemTypeFromInputToOutput"; then
    echo "❌ PROBLEM: Critical symbol is UNDEFINED in $ARCH library"
  else
    echo "❓ Critical symbol not found in $ARCH library"
  fi
  
  echo "Library size: $(ls -lh "onnxruntime-macOS_${ARCH}-static-combined.a" | awk '{print $5}')"
}

# Build both architectures with proper cross-compilation
echo "=== Starting Multi-Architecture Build ==="

# Build x86_64 first (cross-compile on ARM64 host)
build_arch "$ONNX_CONFIG" x86_64

# Build ARM64 (native)
build_arch "$ONNX_CONFIG" arm64

# Verify we have both architecture files with different architectures
echo "=== Pre-Universal Binary Verification ==="

if [ ! -f "onnxruntime-macOS_x86_64-static-combined.a" ]; then
  echo "❌ ERROR: x86_64 library not found"
  exit 1
fi

if [ ! -f "onnxruntime-macOS_arm64-static-combined.a" ]; then
  echo "❌ ERROR: ARM64 library not found"
  exit 1
fi

# Check architectures before combining
X86_ARCH=$(lipo -info "onnxruntime-macOS_x86_64-static-combined.a" | grep -o "arm64\|x86_64" || echo "unknown")
ARM_ARCH=$(lipo -info "onnxruntime-macOS_arm64-static-combined.a" | grep -o "arm64\|x86_64" || echo "unknown")

echo "x86_64 library actual architecture: $X86_ARCH"
echo "ARM64 library actual architecture: $ARM_ARCH"

if [ "$X86_ARCH" = "$ARM_ARCH" ]; then
  echo "❌ ERROR: Both libraries have the same architecture ($X86_ARCH)"
  echo "Cross-compilation failed - cannot create universal binary"
  echo "Will use single architecture instead"
  
  # Use the ARM64 version since that's what we're running on
  mkdir -p libs/macos-arm64_x86_64
  cp "onnxruntime-macOS_arm64-static-combined.a" "libs/macos-arm64_x86_64/libonnxruntime.a"
  echo "⚠️  Created single-architecture library (ARM64 only)"
else
  # Create universal binary
  mkdir -p libs/macos-arm64_x86_64
  echo "=== Creating Universal Binary ==="
  lipo -create "onnxruntime-macOS_x86_64-static-combined.a" \
               "onnxruntime-macOS_arm64-static-combined.a" \
       -output "libs/macos-arm64_x86_64/libonnxruntime.a"
  
  echo "✅ Universal binary created successfully"
  lipo -info "libs/macos-arm64_x86_64/libonnxruntime.a"
fi

# Final verification
echo "=== Final Library Verification ==="
echo "Final library size: $(ls -lh libs/macos-arm64_x86_64/libonnxruntime.a | awk '{print $5}')"

# Test final symbol status
if nm "libs/macos-arm64_x86_64/libonnxruntime.a" 2>/dev/null | grep -E "^[0-9a-fA-F]+ [TtDd] .*propagateElemTypeFromInputToOutput"; then
  echo "🎉 FINAL SUCCESS: Critical symbol is properly DEFINED in final library"
elif nm "libs/macos-arm64_x86_64/libonnxruntime.a" 2>/dev/null | grep -E "^[ ]*U .*propagateElemTypeFromInputToOutput"; then
  echo "❌ FINAL PROBLEM: Critical symbol is still UNDEFINED in final library"
  echo "The linking error will persist"
else
  echo "❓ Critical symbol not found in final library"
fi

# Cleanup
rm -f onnxruntime-macOS_x86_64-static-combined.a
rm -f onnxruntime-macOS_arm64-static-combined.a

echo "=== Build Complete ==="
