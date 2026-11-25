# dev-env

Build-environment tooling: one ccache shared efficiently across git worktrees, CMake presets
that make objects location-independent, and `wt`, a helper for a bare-repo-plus-worktrees
layout. Nothing machine-specific is in this repository: paths, cache sizes and Yocto SDKs come
from a local config file (see "Machine layout").

## Layout

```
~/development/                    DEV_ENV_BASE_DIR
├── myproject/                    container (not a checkout itself)
│   ├── .bare/                    the repository
│   ├── .git                      "gitdir: ./.bare"
│   ├── main/                     worktree, branch main
│   │   ├── CMakeUserPresets.json stub, includes <dev-env>/cmake/presets.json
│   │   ├── compile_commands.json -> build/DEBUG/compile_commands.json
│   │   ├── build/
│   │   │   ├── DEBUG/            preset debug   (installs to DEBUG/dist)
│   │   │   ├── TESTING/          preset testing (BUILD_TESTING=ON)
│   │   │   ├── RELEASE/          preset release
│   │   │   └── YOCTO-<sdk>/      preset yocto after `sdk <sdk>`
│   │   └── ...                   each build dir installs into its own dist/
│   ├── feat-xyz/                 worktree, branch feat-xyz
│   └── pr-1234/                  detached worktree for reviewing PR 1234
└── ...
```

The repository itself can live anywhere (a clone in the home directory, or a read-only
system directory); `wt` and `shell/env.sh` find their own location.

## Setup on a machine

1. **Get it and the tools**: clone this repository, and install `git cmake make ccache mold`,
   a compiler and `python3-venv` with the package manager.
2. **install.sh**: `<dev-env>/install.sh`. Creates the local config
   `~/.config/dev-env/config` (every setting commented out = defaults), generates
   `~/.config/ccache/ccache.conf` from it, hooks `shell/env.sh` into `~/.bashrc`
   (`--no-bashrc` when it is sourced some other way), creates the cache directories and
   lists missing tools. Open a new shell afterwards.
3. **Machine layout**: edit `~/.config/dev-env/config` if the defaults do not fit, then run
   `install.sh` again (it regenerates the ccache config).
4. **Yocto SDKs** (optional): install each SDK wherever you keep them (outside
   `DEV_ENV_BASE_DIR`), then register it: `sdk add <name> <dir>`. `sdk list` shows them.
5. **Repositories as containers**
   ```sh
   wt init git@github.com:example/myproject.git ~/development/myproject
   ```
   If a directory `notes/<container-name>` exists next to the container
   (`~/development/notes/myproject`), `wt init` links it as `<container>/notes`.

   Converting an *existing* plain clone instead of cloning again (clean tree, on `main`):
   ```sh
   mv myproject myproject-tmp && mkdir myproject
   mv myproject-tmp/.git myproject/.bare && git -C myproject/.bare config core.bare true
   echo "gitdir: ./.bare" > myproject/.git
   cd myproject && git worktree add main main && wt setup main && rm -rf ../myproject-tmp
   ```
6. **Emacs** (optional): see "Emacs" below.
7. **Check**: in a worktree `cmake --preset debug && make -C build/DEBUG`, then
   `ccache -s` should show writes and `mold --version` should be what the link step used
   (`grep -l fuse-ld=mold build/DEBUG/CMakeFiles/*/link.txt`).

`shell/env.sh` puts `bin/` on PATH, exports `CMAKE_{C,CXX}_COMPILER_LAUNCHER=ccache`
(so every CMake project uses ccache, presets or not), sets `MAKEFLAGS=-j$(nproc)`,
`CPM_SOURCE_CACHE`, and defines the `sdk` function.

## Machine layout (`~/.config/dev-env/config`)

Shell syntax, read by `shell/env.sh`, `wt` and `install.sh` (defaults in `shell/config.sh`):

| setting               | default                     | meaning |
|-----------------------|-----------------------------|---------|
| `DEV_ENV_BASE_DIR`    | `~/development`             | where the worktree containers live; becomes ccache's `base_dir` |
| `DEV_ENV_CCACHE_DIR`  | `~/.cache/ccache`           | ccache's `cache_dir`, e.g. a directory on a dedicated disk |
| `DEV_ENV_CCACHE_SIZE` | `20G`                       | ccache's `max_size` |
| `DEV_ENV_CPM_CACHE`   | `~/.cache/CPM`              | CPM source cache, shared by all worktrees; outside `DEV_ENV_BASE_DIR` |
| `DEV_ENV_SDK_ROOT`    | `~/.config/dev-env/sdks`    | the SDKs `sdk` knows: one directory or symlink per SDK |

A dedicated cache disk: mount it (with `nofail`, so the machine boots without it), set
`DEV_ENV_CCACHE_DIR` to a directory on it and run `install.sh`. If the ccache directory
cannot be created, *every compile fails* with a ccache error; `install.sh` warns about it.
To move the CPM cache to that disk too, keep `DEV_ENV_CPM_CACHE` at its old path and make
that path a symlink: the recorded dependency paths, and with them the ccache entries, stay
valid.

## Daily use

```sh
wt init git@github.com:example/myproject.git ~/development/myproject   # once per repo
cd ~/development/myproject

wt add feat-xyz                 # new branch from origin/main, or check out existing feat-xyz
wt add feat-xyz origin/other    # new branch starting from somewhere else
wt review 1234                  # detached worktree at head of PR 1234, re-run to update
wt list
wt rm feat-xyz                  # branch survives, worktree and its build dir go away
wt fetch                        # one fetch serves all worktrees

cd feat-xyz
cmake --preset debug            # Unix Makefiles, Debug, ccache, prefix-map, mold -> build/DEBUG
make -C build/DEBUG             # or: cmake --build --preset debug
make -C build/DEBUG install     # -> feat-xyz/build/DEBUG/dist
cmake --preset testing          # same + BUILD_TESTING=ON -> build/TESTING
make -C build/TESTING && ctest --preset testing
cmake --preset release          # -> build/RELEASE

sdk add my-sdk /opt/sdks/my-sdk # once: register an installed Yocto SDK under a name
sdk                             # lists the registered SDKs (also: sdk list; forget one: sdk rm <name>)
sdk my-sdk                      # sources its environment-setup-*, exports DEV_ENV_SDK + OE_CMAKE_TOOLCHAIN_FILE
cmake --preset yocto            # -> build/YOCTO-my-sdk, SDK toolchain file, the SDK's own cmake
make -C build/YOCTO-my-sdk
```

A branch can be checked out in only one worktree at a time. That is why reviews use
detached worktrees.

For a plain clone that is not in a container: `setup-cmake-project [dir]` creates the
same stub, symlink and excludes.

## Presets (`cmake/presets.json`)

| preset    | build dir            | type           | notes                                      |
|-----------|----------------------|----------------|--------------------------------------------|
| `debug`   | `build/DEBUG`        | Debug          | ccache, prefix-map, mold, zstd debug sections |
| `testing` | `build/TESTING`      | Debug          | as debug + `BUILD_TESTING=ON`, ctest preset |
| `release` | `build/RELEASE`      | Release        | as debug                                   |
| `yocto`   | `build/YOCTO-<sdk>`  | RelWithDebInfo | visible only after `sdk <name>`; SDK linker |

All presets export `compile_commands.json`.

The stub `CMakeUserPresets.json` in each worktree only includes this file, so edits here
apply everywhere. `cmake/dev-env.cmake` is injected through
`CMAKE_PROJECT_TOP_LEVEL_INCLUDES` and adds, for the whole tree including CPM deps:

* `-ffile-prefix-map=<worktree>=.`  Debug info and `__FILE__` become relative, so identical
  sources in different worktrees produce byte-identical objects.
* `-fuse-ld=mold` in the native presets. Link phase several times faster; CI and the target
  still link with GNU ld, which is the safety net for the rare linker-behaviour difference.
* `DEV_ENV_COMPRESS_DEBUG` (native presets: ON): mold `--compress-debug-sections=zstd`.
  Executables, shared libraries and `dist/` shrink by about half (489M -> 234M measured on 40
  bench binaries); `.o`/`.a` are unchanged. Link-only, so ccache hashes are unaffected.
* `DEV_ENV_SPLIT_DWARF` (default OFF): `-gsplit-dwarf`, debug info stays in `.dwo` files next
  to the objects instead of being copied into every binary. Changes the compile flags, so
  turning it on costs one cold build through ccache (the first worktree pays, others then hit).

Both are cache variables: an existing build dir only picks them up when `cmake --preset` is
re-run there (or with `-D...` on its own). To free space without losing the configuration,
`cmake --build build/TESTING --target clean && rm -rf build/TESTING/dist` keeps
`CMakeCache.txt`, `_deps` and the venv (<1G) and drops the ~20G of artifacts.

Native and SDK objects never collide in ccache: the compiler binary (`compiler_check = content`),
all flags and the preprocessed content including sysroot headers are part of the hash.

### Yocto SDKs

No SDK is known to this repository. `sdk add <name> <dir>` (in `shell/env.sh`) registers an
installed SDK: a symlink `$DEV_ENV_SDK_ROOT/<name>` to `<dir>`, which must contain an
`environment-setup-*` script. `sdk rm <name>` removes the link only. `sdk <name>` sources the
script and sets `OE_CMAKE_TOOLCHAIN_FILE` to the SDK's `OEToolchainConfig.cmake`; SDKs that
ship none (old ones) get `cmake/oe-toolchain.cmake`, a copy of a recent one. The SDK
environment is permanent for that shell; use a subshell to keep it scoped. Keep SDKs outside
`DEV_ENV_BASE_DIR` (`sdk add` warns otherwise; the reason is in the ccache section).

## ccache (`ccache/ccache.conf.in` + local settings)

`install.sh` writes `~/.config/ccache/ccache.conf`: the three local settings from the machine
layout, then `ccache/ccache.conf.in`. Why ccache's defaults are not good enough: at 5 GiB the
cache evicts constantly, and with `hash_dir = true` plus no `base_dir` the absolute path of
every file is part of the hash, so two worktrees never share an object.

| setting                      | effect                                                                |
|------------------------------|-----------------------------------------------------------------------|
| `max_size` (local)           | `DEV_ENV_CCACHE_SIZE`; large enough that nothing useful is evicted     |
| `cache_dir` (local)          | `DEV_ENV_CCACHE_DIR`; the location does not influence hashing          |
| `base_dir` (local)           | `DEV_ENV_BASE_DIR`; worktree paths hashed relative to the build dir; CPM cache and SDKs stay outside on purpose |
| `hash_dir = false`           | cwd not in the hash                                                   |
| `sloppiness = include_file_mtime,include_file_ctime,...` | direct mode works on freshly checked-out files |
| `compiler_check = content`   | correct with several toolchains and after package upgrades            |
| `depend_mode = true`         | hits skip the preprocessor, using the `-MD` depfiles make requests    |

`base_dir` rewrites absolute paths into paths *relative to the build directory*. That is
depth-dependent: from `main/build/DEBUG/x` a file in `~/.cache/CPM` is one `../` shorter
than from `feat/xyz/build/DEBUG/x`. So everything that every worktree references (CPM
sources, SDK sysroots) must live outside `base_dir`, where its absolute path is identical
for all worktrees. Paths inside a worktree are fine at any nesting depth.

Check hit rates with `ccache -s` (`ccache -z` resets the counters). To see why a single
file missed: `CCACHE_DEBUG=1 CCACHE_DEBUGDIR=/tmp/ccdbg make -C build/DEBUG <target>` and
read the `.ccache-log` next to the object path under `/tmp/ccdbg`.

## gdb

With the prefix map, the debug info says `./src/...` and the compilation dir is `.`.
Start gdb from the worktree root and everything resolves. From elsewhere:

```
(gdb) set substitute-path . /path/to/myproject/feat-xyz
```

## Emacs (Spacemacs, helm-make, projectile)

`emacs/jchh-dev-env.el` is loaded from here, your layer stays as it is. Enable with:

```elisp
(use-package jchh-dev-env
  :load-path "<dev-env>/emacs"
  :config (jchh-dev-env-enable))
(spacemacs/declare-prefix "cW" "worktrees")
(spacemacs/set-leader-keys
  "cS"  'jchh-dev-env-select-build-dir  ; replaces jchh-helm-make-select-build-dir
  "cWs" 'jchh-dev-env-select-build-dir  ; same, under the worktree prefix
  "cWr" 'jchh-dev-env-rebuild           ; make (all) in the current project's build dir
  "cWw" 'jchh-wt-switch                 ; switch projectile to another worktree
  "cWa" 'jchh-wt-add                    ; wt add <name>, then switch to it
  "cWp" 'jchh-wt-review                 ; wt review <pr>, then switch to it
  "cWk" 'jchh-wt-remove                 ; wt rm (asks, never forces)
  "cWc" 'jchh-dev-env-configure)        ; cmake --preset <p> here (yocto via sdk), adopt build dir
```

Rollback: remove those lines (or `M-x jchh-dev-env-disable`); the old function keeps
working, since the old package is untouched.

| what | how |
|------|-----|
| build dir per worktree, persistent | `SPC c S` (or `SPC c W s`) writes `helm-make-build-dir` (relative, e.g. `build/DEBUG`) into the worktree's `.dir-locals.el`; `wt setup` seeds it with `build/DEBUG`. Every buffer under the worktree gets it buffer-locally, so `SPC c c` builds the current file's project. |
| `SPC c r` per project | `compilation-buffer-name-function` = projectile's, so each project has its own `*compilation*<name>` and `recompile` reruns that one. Session-only; `SPC c W r` needs no history. |
| SDK environment per build dir | `cmake --preset yocto` writes `<build>/.env` (dev-env.cmake). `compilation-start` is advised to pass `<default-directory>/.env` to that compile process only. Native build dirs have no `.env`, nothing leaks, no `setenv`. `wt env <dir>` prints it. |
| worktrees | `jchh-wt-*` shell out to `wt`; the new worktree is added to projectile's known projects and switched to, then `jchh-dev-env-switch-action` runs (default `magit-status`). `jchh-wt-remove` asks and never forces. |
| configure | `SPC c W c` offers the native presets plus `yocto <sdk>` for every registered SDK, runs the configure in a compilation buffer (yocto through `sdk`), and adopts the resulting build dir when it succeeds. |

`helm-make-named-buffer` must stay nil (it renames the compilation buffer and breaks the
per-project lookup). Root-level `.env*` files are still passed to the old `jchh-load-env`
if that function is loaded.
