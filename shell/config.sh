# Machine layout of dev-env: defaults, overridden by the local config file. Sourced by
# shell/env.sh, bin/wt and install.sh; nothing machine-specific lives in this repository.
#
# Local config: ${XDG_CONFIG_HOME:-~/.config}/dev-env/config, shell syntax KEY=VALUE
# (install.sh creates it with every setting commented out). After changing the ccache
# settings run install.sh again: it regenerates ~/.config/ccache/ccache.conf from them.
DEV_ENV_CONFIG="${DEV_ENV_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/dev-env/config}"
# shellcheck disable=SC1090
[ -f "$DEV_ENV_CONFIG" ] && . "$DEV_ENV_CONFIG"

# Where the worktree containers live. ccache hashes paths below it relative to the build
# dir (base_dir), so identical sources in different worktrees share cache entries.
: "${DEV_ENV_BASE_DIR:=$HOME/development}"
# ccache: location and size limit of the cache.
: "${DEV_ENV_CCACHE_DIR:=$HOME/.cache/ccache}"
: "${DEV_ENV_CCACHE_SIZE:=20G}"
# CPM source cache shared by all worktrees. Must stay OUTSIDE DEV_ENV_BASE_DIR.
: "${DEV_ENV_CPM_CACHE:=$HOME/.cache/CPM}"
# Yocto SDKs known to `sdk`: one entry per SDK, a directory or a symlink to one
# (`sdk add <name> <dir>` creates the symlink).
: "${DEV_ENV_SDK_ROOT:=${XDG_CONFIG_HOME:-$HOME/.config}/dev-env/sdks}"
