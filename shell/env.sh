# Sourced from ~/.bashrc (added by dev-env/install.sh) or from a system profile script.
export DEV_ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
. "$DEV_ENV_DIR/shell/config.sh"
export DEV_ENV_BASE_DIR DEV_ENV_SDK_ROOT

case ":$PATH:" in *":$DEV_ENV_DIR/bin:"*) ;; *) export PATH="$DEV_ENV_DIR/bin:$PATH" ;; esac

# Every CMake project on this machine compiles through ccache, presets or not.
export CMAKE_C_COMPILER_LAUNCHER=ccache
export CMAKE_CXX_COMPILER_LAUNCHER=ccache

# Plain `make` in a build dir uses all cores (Emacs cmake layer runs make, not ninja).
export MAKEFLAGS="-j$(nproc)"

# Shared CPM source cache: dependencies are stored once per commit hash, not per worktree.
export CPM_SOURCE_CACHE="${CPM_SOURCE_CACHE:-$DEV_ENV_CPM_CACHE}"

# Yocto SDKs. None are known to this repository; each machine registers its own:
#   sdk add <name> <dir>   register the SDK installed in <dir> (has environment-setup-*)
#   sdk rm <name>          forget it (the SDK itself is not touched)
#   sdk list               list the registered SDKs (also: sdk without arguments)
#   sdk <name>             activate it for the current shell
# Activating sources the SDK's environment-setup script (CC, CXX, sysroot, PATH incl. the SDK's
# cmake) and exports what the "yocto" preset needs: DEV_ENV_SDK (names build/YOCTO-<name>) and
# OE_CMAKE_TOOLCHAIN_FILE (the SDK's own OEToolchainConfig.cmake, or cmake/oe-toolchain.cmake
# for SDKs without one). The environment change is permanent for this shell; use a subshell if
# you want it scoped. Registered SDKs are entries of $DEV_ENV_SDK_ROOT.
sdk() {
    local base="$DEV_ENV_SDK_ROOT" n
    case "${1:-}" in
    ""|list)
        echo "SDKs in $base (register with: sdk add <name> <dir>):" >&2
        for n in "$base"/*; do
            [ -e "$n" ] && ls "$n"/environment-setup-* >/dev/null 2>&1 && echo "  ${n##*/}"
        done
        [ "${1:-}" = list ]; return
        ;;
    add)
        [ $# -eq 3 ] || { echo "usage: sdk add <name> <dir>" >&2; return 1; }
        case "$2" in add|rm|list|""|*[!A-Za-z0-9._-]*) echo "sdk: invalid name '$2' (letters, digits, . _ -)" >&2; return 1 ;; esac
        local dir; dir="$(cd "$3" 2>/dev/null && pwd -P)" || { echo "sdk: no directory $3" >&2; return 1; }
        ls "$dir"/environment-setup-* >/dev/null 2>&1 || { echo "sdk: no environment-setup-* in $dir" >&2; return 1; }
        case "$dir/" in "$DEV_ENV_BASE_DIR"/*)
            echo "sdk: WARNING: $dir is below DEV_ENV_BASE_DIR ($DEV_ENV_BASE_DIR); ccache then hashes" >&2
            echo "     the sysroot paths per worktree depth. Keep SDKs outside it." >&2 ;;
        esac
        [ ! -e "$base/$2" ] || [ -L "$base/$2" ] || { echo "sdk: $base/$2 exists and is not a link" >&2; return 1; }
        mkdir -p "$base" && ln -sfn "$dir" "$base/$2" && echo "sdk: $2 -> $dir" >&2
        return
        ;;
    rm)
        [ $# -eq 2 ] || { echo "usage: sdk rm <name>" >&2; return 1; }
        [ -L "$base/$2" ] || { echo "sdk: $2 is not a registered link in $base (nothing removed)" >&2; return 1; }
        rm "$base/$2" && echo "sdk: forgot $2 (the SDK itself is untouched)" >&2
        return
        ;;
    esac
    [ $# -eq 1 ] || { echo "usage: sdk [list] | sdk <name> | sdk add <name> <dir> | sdk rm <name>" >&2; return 1; }
    local dir="$base/$1" script toolchain
    script="$(ls "$dir"/environment-setup-* 2>/dev/null | head -1)"
    [ -n "$script" ] || { echo "sdk: unknown SDK '$1' (no environment-setup-* in $dir); see: sdk list" >&2; return 1; }
    # shellcheck disable=SC1090
    source "$script"
    toolchain="$OECORE_NATIVE_SYSROOT/usr/share/cmake/OEToolchainConfig.cmake"
    if [ ! -f "$toolchain" ]; then
        # older SDKs ship no toolchain file; use dev-env's copy of a recent one
        toolchain="$DEV_ENV_DIR/cmake/oe-toolchain.cmake"
        echo "sdk: $1 ships no OEToolchainConfig.cmake, using fallback $toolchain" >&2
    fi
    export DEV_ENV_SDK="$1"
    export OE_CMAKE_TOOLCHAIN_FILE="$toolchain"
    echo "sdk: $1 active, cmake $(cmake --version | head -1 | cut -d' ' -f3); now: cmake --preset yocto && make -C build/YOCTO-$1"
}
