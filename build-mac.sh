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
  
  # Comprehensive library discovery
  echo "=== Comprehensive Library Discovery for ${ARCH} ==="
  
  # Find ALL .a files in the build directory
  echo "All .a files found:"
  find "$BUILD_DIR" -name "*.a" -type f | sort
  
  # Look for ONNX-related files specifically
  echo ""
  echo "ONNX-related libraries:"
  find "$BUILD_DIR" -name "*onnx*.a" -type f | sort
  
  # Look in _deps directories too
  echo ""
  echo "Dependencies libraries:"
  find "$BUILD_DIR/_deps" -name "*.a" -type f 2>/dev/null | sort || echo "(No _deps directory)"
  
  # Check specific critical libraries
  echo ""
  echo "=== Critical Library Analysis ==="
  
  CRITICAL_LIBS=(
    "${BUILD_DIR}/libonnx.a"
    "${BUILD_DIR}/libonnx_proto.a"
    "${BUILD_DIR}/_deps/onnx-build/libonnx.a"
    "${BUILD_DIR}/_deps/onnx-build/libonnx_proto.a"
    "${BUILD_DIR}/external/onnx/libonnx.a"
    "${BUILD_DIR}/external/onnx/libonnx_proto.a"
  )
  
  FOUND_ONNX_LIBS=()
  
  for lib in "${CRITICAL_LIBS[@]}"; do
    if [ -f "$lib" ]; then
      echo "✅ Found: $lib"
      FOUND_ONNX_LIBS+=("$lib")
      
      # Check if this library contains the critical symbol as DEFINED (not undefined)
      if nm "$lib" 2>/dev/null | grep -E "^[0-9a-fA-F]+ [TtDd] .*propagateElemTypeFromInputToOutput"; then
        echo "  🎯 CRITICAL: This library DEFINES propagateElemTypeFromInputToOutput!"
      elif nm "$lib" 2>/dev/null | grep -E "^[ ]*U .*propagateElemTypeFromInputToOutput"; then
        echo "  ⚠️  This library only REFERENCES propagateElemTypeFromInputToOutput (undefined)"
      elif nm "$lib" 2>/dev/null | grep -q "propagateElemTypeFromInputToOutput"; then
        echo "  ❓ This library mentions propagateElemTypeFromInputToOutput (check manually)"
        nm "$lib" 2>/dev/null | grep "propagateElemTypeFromInputToOutput"
      else
        echo "  ❌ This library does NOT contain propagateElemTypeFromInputToOutput"
      fi
    else
      echo "❌ Not found: $lib"
    fi
  done
  
  # If we didn't find the critical ONNX libraries in standard locations, search more broadly
  if [ ${#FOUND_ONNX_LIBS[@]} -eq 0 ]; then
    echo ""
    echo "=== Broad Search for ONNX Libraries ==="
    find "$BUILD_DIR" -name "*.a" -exec sh -c 'nm "$1" 2>/dev/null | grep -q "onnx::" && echo "ONNX symbols found in: $1"' _ {} \;
  fi
  
  # Now build the combined library with all available libraries
  echo ""
  echo "=== Building Combined Library for ${ARCH} ==="
  
  # Get ALL available .a files
  ALL_AVAILABLE_LIBS=($(find "$BUILD_DIR" -name "*.a" -type f | sort))
  
  echo "Found ${#ALL_AVAILABLE_LIBS[@]} total libraries"
  
  # Filter out test libraries and include all others
  FILTERED_LIBS=()
  for lib in "${ALL_AVAILABLE_LIBS[@]}"; do
    # Skip test-only libraries but include everything else
    if [[ "$lib" != *test* ]] || [[ "$lib" == *test_utils* ]]; then
      FILTERED_LIBS+=("$lib")
      echo "✅ Including: $(basename "$lib")"
    else
      echo "⏭️  Skipping test lib: $(basename "$lib")"
    fi
  done
  
  # Create the combined library with ALL filtered libraries
  echo ""
  echo "=== Creating Combined Library with ${#FILTERED_LIBS[@]} components ==="
  
  if [ ${#FILTERED_LIBS[@]} -gt 0 ]; then
    libtool -static -o "onnxruntime-macOS_${ARCH}-static-combined.a" "${FILTERED_LIBS[@]}"
    echo "✅ Combined library created successfully"
    
    # Verify the symbol is now properly defined
    echo ""
    echo "=== Final Symbol Verification ==="
    if nm "onnxruntime-macOS_${ARCH}-static-combined.a" 2>/dev/null | grep -E "^[0-9a-fA-F]+ [TtDd] .*propagateElemTypeFromInputToOutput"; then
      echo "🎉 SUCCESS: propagateElemTypeFromInputToOutput is DEFINED in combined library!"
    elif nm "onnxruntime-macOS_${ARCH}-static-combined.a" 2>/dev/null | grep -E "^[ ]*U .*propagateElemTypeFromInputToOutput"; then
      echo "❌ PROBLEM: propagateElemTypeFromInputToOutput is still UNDEFINED in combined library"
      echo "This means the symbol definition is missing from all included libraries"
    else
      echo "❓ Symbol not found at all in combined library"
    fi
    
    # Show some statistics
    echo ""
    echo "=== Library Statistics ==="
    echo "Combined library size: $(ls -lh "onnxruntime-macOS_${ARCH}-static-combined.a" | awk '{print $5}')"
    echo "Total symbols: $(nm "onnxruntime-macOS_${ARCH}-static-combined.a" 2>/dev/null | wc -l || echo 'unknown')"
    echo "ONNX-related symbols: $(nm "onnxruntime-macOS_${ARCH}-static-combined.a" 2>/dev/null | grep -c "onnx" || echo '0')"
    
  else
    echo "❌ ERROR: No libraries found to combine!"
    exit 1
  fi
}

# Build both architectures
build_arch "$ONNX_CONFIG" x86_64
build_arch "$ONNX_CONFIG" arm64

# Create universal binary only if both arch builds succeeded
if [ -f "onnxruntime-macOS_x86_64-static-combined.a" ] && [ -f "onnxruntime-macOS_arm64-static-combined.a" ]; then
  mkdir -p libs/macos-arm64_x86_64
  echo "=== Creating Universal Binary ==="
  lipo -create onnxruntime-macOS_x86_64-static-combined.a \
               onnxruntime-macOS_arm64-static-combined.a \
       -output "libs/macos-arm64_x86_64/libonnxruntime.a"

  # Final verification of universal binary
  echo "=== Final Universal Binary Verification ==="
  lipo -info "libs/macos-arm64_x86_64/libonnxruntime.a"
  
  # Test the critical symbol in both architectures of the universal binary
  lipo -extract arm64 "libs/macos-arm64_x86_64/libonnxruntime.a" -output /tmp/test_arm64.a
  lipo -extract x86_64 "libs/macos-arm64_x86_64/libonnxruntime.a" -output /tmp/test_x86_64.a
  
  echo ""
  echo "ARM64 architecture symbol status:"
  if nm /tmp/test_arm64.a 2>/dev/null | grep -E "^[0-9a-fA-F]+ [TtDd] .*propagateElemTypeFromInputToOutput"; then
    echo "🎉 ARM64: propagateElemTypeFromInputToOutput is DEFINED"
  elif nm /tmp/test_arm64.a 2>/dev/null | grep -E "^[ ]*U .*propagateElemTypeFromInputToOutput"; then
    echo "❌ ARM64: propagateElemTypeFromInputToOutput is UNDEFINED"
  else
    echo "❓ ARM64: propagateElemTypeFromInputToOutput not found"
  fi
  
  echo ""
  echo "x86_64 architecture symbol status:"
  if nm /tmp/test_x86_64.a 2>/dev/null | grep -E "^[0-9a-fA-F]+ [TtDd] .*propagateElemTypeFromInputToOutput"; then
    echo "🎉 x86_64: propagateElemTypeFromInputToOutput is DEFINED"
  elif nm /tmp/test_x86_64.a 2>/dev/null | grep -E "^[ ]*U .*propagateElemTypeFromInputToOutput"; then
    echo "❌ x86_64: propagateElemTypeFromInputToOutput is UNDEFINED"
  else
    echo "❓ x86_64: propagateElemTypeFromInputToOutput not found"
  fi
  
  # Clean up temp files
  rm -f /tmp/test_arm64.a /tmp/test_x86_64.a
  
  # Clean up intermediate files
  rm onnxruntime-macOS_x86_64-static-combined.a
  rm onnxruntime-macOS_arm64-static-combined.a
  
  echo ""
  echo "=== Build Complete ==="
  echo "Universal library: libs/macos-arm64_x86_64/libonnxruntime.a"
  echo "Library size: $(ls -lh libs/macos-arm64_x86_64/libonnxruntime.a | awk '{print $5}')"
else
  echo "❌ ERROR: Could not create universal binary - individual architecture builds failed"
  exit 1
fi
