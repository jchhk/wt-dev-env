# Fallback CMake toolchain file for Yocto SDKs that ship no OEToolchainConfig.cmake (old SDKs).
# Copy of the file recent SDKs install to $OECORE_NATIVE_SYSROOT/usr/share/cmake/
# OEToolchainConfig.cmake (from openembedded-core, meta/recipes-devtools/cmake/cmake/
# OEToolchainConfig.cmake, MIT), minus the include of an OEToolchainConfig.cmake.d directory.
# It only reads variables that every environment-setup-* script exports. Selected by the `sdk`
# shell function in shell/env.sh when the SDK's own file does not exist.

set( CMAKE_SYSTEM_NAME Linux )
set( CMAKE_C_FLAGS $ENV{CFLAGS} CACHE STRING "" FORCE )
set( CMAKE_CXX_FLAGS $ENV{CXXFLAGS}  CACHE STRING "" FORCE )
set( CMAKE_ASM_FLAGS ${CMAKE_C_FLAGS} CACHE STRING "" FORCE )
set( CMAKE_LDFLAGS_FLAGS ${CMAKE_CXX_FLAGS} CACHE STRING "" FORCE )
set( CMAKE_SYSROOT $ENV{OECORE_TARGET_SYSROOT} )

set( CMAKE_FIND_ROOT_PATH $ENV{OECORE_TARGET_SYSROOT} )
set( CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER )
set( CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY )
set( CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY )
set( CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY )

set(CMAKE_FIND_LIBRARY_CUSTOM_LIB_SUFFIX "$ENV{OE_CMAKE_FIND_LIBRARY_CUSTOM_LIB_SUFFIX}")

# Set CMAKE_SYSTEM_PROCESSOR from the sysroot name (assuming processor-distro-os).
if ($ENV{OECORE_TARGET_SYSROOT} MATCHES "/sysroots/([a-zA-Z0-9_-]+)-.+")
  set(CMAKE_SYSTEM_PROCESSOR ${CMAKE_MATCH_1})
endif()
