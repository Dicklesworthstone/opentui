#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail
set -o errtrace

if [[ ${DEBUG:-} =~ ^(1|yes|true)$ ]]; then
  set -o xtrace
fi

SCRIPT_PATH="${BASH_SOURCE[0]}"
while [[ -L "$SCRIPT_PATH" ]]; do
  SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
  SCRIPT_PATH="$(readlink "$SCRIPT_PATH")"
  if [[ "$SCRIPT_PATH" != /* ]]; then
    SCRIPT_PATH="$SCRIPT_DIR/$SCRIPT_PATH"
  fi
done
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
readonly SCRIPT_DIR
OPENTUI_DEFAULT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly OPENTUI_DEFAULT
OPENCODE_DEFAULT="$(cd "${OPENTUI_DEFAULT}/.." && pwd)/opencode"
readonly OPENCODE_DEFAULT

opentui_root="${OPENTUI_ROOT:-"$OPENTUI_DEFAULT"}"
opencode_root="${OPENCODE_ROOT:-"$OPENCODE_DEFAULT"}"
link_mode="dist"
flag_release=false
flag_debug_native=false
flag_skip_build=false
flag_skip_opencode=false
flag_run=false
flag_bench=false
bench_runs=10
bench_mode="help"
flag_isolated=false
flag_shell=false
flag_verbose=false
flag_dry_run=false
expected_core_version=""
expected_solid_version=""

declare -a cleanup_tasks=()

BOLD=""
RED=""
YELLOW=""
BLUE=""
NC=""

init_colors() {
  if [[ ! -t 1 || -z "${TERM:-}" || "${TERM:-}" == "dumb" || -n "${NO_COLOR:-}" ]]; then
    return
  fi

  if ! command -v tput >/dev/null 2>&1; then
    return
  fi

  local colors=""
  colors="$(tput colors 2>/dev/null || true)"
  if [[ -z "$colors" || "$colors" -lt 8 ]]; then
    return
  fi

  BOLD="$(tput bold 2>/dev/null || true)"
  RED="$(tput setaf 1 2>/dev/null || true)"
  YELLOW="$(tput setaf 3 2>/dev/null || true)"
  BLUE="$(tput setaf 4 2>/dev/null || true)"
  NC="$(tput sgr0 2>/dev/null || true)"
}

err() {
  printf "%berror:%b %s\n" "$RED" "$NC" "$*" >&2
}

warn() {
  printf "%bwarning:%b %s\n" "$YELLOW" "$NC" "$*" >&2
}

info() {
  if ! $flag_verbose; then
    return 0
  fi
  printf "%binfo:%b %s\n" "$BLUE" "$NC" "$*" >&2
}

step() {
  printf "%b==> %s%b\n" "$BOLD" "$*" "$NC" >&2
}

show_usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") [options]

Build local opentui and wire it into opencode.

Options:
  --opentui <path>    Path to opentui checkout (default: OPENTUI_ROOT or ${OPENTUI_DEFAULT})
  --opencode <path>   Path to opencode checkout (default: OPENCODE_ROOT or ${OPENCODE_DEFAULT})
  --release           Build opencode release binary (script/build.ts --single)
  --debug-native      Build core native with Zig Debug optimize mode
  --skip-build        Skip opentui TS builds (native may still run if missing)
  --skip-opencode     Build opentui only, skip linking/building opencode
  --run               Run opencode after build (dev mode or release binary)
  --isolated          Run/bench with isolated config (no plugins, skills, etc.)
  --shell             Print isolated env exports, then exit (no build)
  --bench             Benchmark startup timing
  --bench-runs <n>    Number of benchmark runs (default: 10)
  --bench-mode <m>    Benchmark mode: help | tui | tui-ready (default: help)
  --dist              Link built dist directories (default)
  --source            Link package source directories (dev mode only)
  --verbose, -v       Enable verbose logging
  --dry-run           Print planned actions without making changes
  --help, -h          Show this help
EOF
}

cleanup_register() {
  cleanup_tasks+=("$1")
}

run_cleanup() {
  local idx
  for ((idx = ${#cleanup_tasks[@]} - 1; idx >= 0; idx--)); do
    "${cleanup_tasks[$idx]}" || true
  done
}

print_stack_trace() {
  local frame=0
  while caller "$frame" >&2; do
    frame=$((frame + 1))
  done
}

on_error() {
  local exit_code=$?
  err "Command failed with exit code ${exit_code}: ${BASH_COMMAND}"
  print_stack_trace
  exit "$exit_code"
}

setup_traps() {
  trap run_cleanup EXIT
  trap on_error ERR
}

expand_home() {
  local path="$1"
  if [[ "$path" == "~" ]]; then
    printf "%s\n" "$HOME"
    return 0
  fi

  if [[ "$path" =~ ^~/ ]]; then
    printf "%s/%s\n" "$HOME" "${path:2}"
    return 0
  fi

  printf "%s\n" "$path"
}

resolve_existing_dir() {
  local dir_path="$1"
  local expanded=""

  expanded="$(expand_home "$dir_path")"
  if [[ ! -d "$expanded" ]]; then
    err "Directory does not exist: $expanded"
    exit 1
  fi

  (cd "$expanded" && pwd)
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
    --opentui)
      opentui_root="${2:?--opentui requires a value}"
      shift 2
      ;;
    --opencode)
      opencode_root="${2:?--opencode requires a value}"
      shift 2
      ;;
    --release)
      flag_release=true
      shift
      ;;
    --debug-native)
      flag_debug_native=true
      shift
      ;;
    --skip-build)
      flag_skip_build=true
      shift
      ;;
    --skip-opencode)
      flag_skip_opencode=true
      shift
      ;;
    --run)
      flag_run=true
      shift
      ;;
    --isolated)
      flag_isolated=true
      shift
      ;;
    --shell)
      flag_shell=true
      flag_isolated=true
      shift
      ;;
    --bench)
      flag_bench=true
      shift
      ;;
    --bench-runs)
      flag_bench=true
      bench_runs="${2:?--bench-runs requires a value}"
      shift 2
      ;;
    --bench-mode)
      flag_bench=true
      bench_mode="${2:?--bench-mode requires a value}"
      shift 2
      ;;
    --dist)
      link_mode="dist"
      shift
      ;;
    --source)
      link_mode="source"
      shift
      ;;
    --verbose | -v)
      flag_verbose=true
      shift
      ;;
    --dry-run)
      flag_dry_run=true
      shift
      ;;
    --help | -h)
      show_usage
      exit 0
      ;;
    --*)
      err "Unknown flag: $1"
      exit 1
      ;;
    *)
      err "Unexpected positional argument: $1"
      exit 1
      ;;
    esac
  done

  if $flag_release && [[ "$link_mode" == "source" ]]; then
    err "--release requires --dist linking"
    exit 1
  fi

  if [[ ! "$bench_runs" =~ ^[0-9]+$ ]] || ((bench_runs < 1)); then
    err "--bench-runs must be a positive integer"
    exit 1
  fi

  case "$bench_mode" in
  help | tui | tui-ready) ;;
  *)
    err "--bench-mode must be one of: help, tui, tui-ready"
    exit 1
    ;;
  esac

  if $flag_bench && $flag_skip_opencode; then
    err "--bench cannot be used with --skip-opencode"
    exit 1
  fi
}

validate_paths() {
  [[ -f "$opentui_root/package.json" ]] || {
    err "Not an opentui checkout: $opentui_root (no package.json)"
    exit 1
  }

  if ! $flag_skip_opencode; then
    [[ -f "$opencode_root/packages/opencode/package.json" ]] || {
      err "Not an opencode checkout: $opencode_root"
      exit 1
    }
  fi
}

detect_platform() {
  local os arch
  os="$(uname -s)"
  arch="$(uname -m)"

  case "$os" in
  Darwin)
    os="darwin"
    ;;
  Linux)
    os="linux"
    ;;
  *)
    err "Unsupported OS: $os"
    exit 1
    ;;
  esac

  case "$arch" in
  x86_64)
    arch="x64"
    ;;
  aarch64 | arm64)
    arch="arm64"
    ;;
  *)
    err "Unsupported arch: $arch"
    exit 1
    ;;
  esac

  echo "$os" "$arch"
}

native_package_name() {
  local platform arch
  read -r platform arch < <(detect_platform)
  printf "@opentui/core-%s-%s\n" "$platform" "$arch"
}

native_package_source_dir() {
  local native_pkg
  native_pkg="$(native_package_name)"
  printf "%s/packages/core/node_modules/%s\n" "$opentui_root" "$native_pkg"
}

check_dependencies() {
  local -a missing=()
  local need_zig=false

  if ! command -v bun >/dev/null 2>&1; then
    missing+=("bun")
  fi

  if ! $flag_skip_build; then
    need_zig=true
  fi

  if $flag_skip_build && ! $flag_skip_opencode; then
    local native_src
    native_src="$(native_package_source_dir)"
    if [[ ! -d "$native_src" ]]; then
      need_zig=true
      warn "--skip-build requested but native package is missing; native build will run"
    fi
  fi

  if $need_zig && ! command -v zig >/dev/null 2>&1; then
    missing+=("zig")
  fi

  if $flag_bench && [[ "$bench_mode" != "help" ]] && ! command -v python3 >/dev/null 2>&1; then
    missing+=("python3")
  fi

  if ((${#missing[@]} > 0)); then
    err "Missing required dependencies: ${missing[*]}"
    exit 1
  fi
}

read_package_version() {
  local package_json="$1"
  if [[ ! -f "$package_json" ]]; then
    err "package.json not found: $package_json"
    exit 1
  fi

  local version=""
  version="$(bun --eval 'const file = process.argv[1]; const json = JSON.parse(await Bun.file(file).text()); if (typeof json.version !== "string") process.exit(2); console.log(json.version)' "$package_json" 2>/dev/null || true)"
  if [[ -z "$version" ]]; then
    err "Failed to read package version from $package_json"
    exit 1
  fi

  printf "%s\n" "$version"
}

load_expected_versions() {
  expected_core_version="$(read_package_version "$opentui_root/packages/core/package.json")"
  expected_solid_version="$(read_package_version "$opentui_root/packages/solid/package.json")"
}

canonical_dir() {
  local dir="$1"
  (cd "$dir" && pwd -P)
}

validate_local_link_artifacts() {
  local core_pkg_json=""
  local solid_pkg_json=""

  if [[ "$link_mode" == "dist" ]]; then
    core_pkg_json="$opentui_root/packages/core/dist/package.json"
    solid_pkg_json="$opentui_root/packages/solid/dist/package.json"
  else
    core_pkg_json="$opentui_root/packages/core/package.json"
    solid_pkg_json="$opentui_root/packages/solid/package.json"
  fi

  local core_version solid_version
  core_version="$(read_package_version "$core_pkg_json")"
  solid_version="$(read_package_version "$solid_pkg_json")"

  if [[ "$core_version" != "$expected_core_version" ]]; then
    err "Core link source version mismatch: expected $expected_core_version from $opentui_root/packages/core/package.json, got $core_version from $core_pkg_json"
    err "If using --skip-build, rebuild without it to refresh dist artifacts"
    exit 1
  fi

  if [[ "$solid_version" != "$expected_solid_version" ]]; then
    err "Solid link source version mismatch: expected $expected_solid_version from $opentui_root/packages/solid/package.json, got $solid_version from $solid_pkg_json"
    err "If using --skip-build, rebuild without it to refresh dist artifacts"
    exit 1
  fi

  local native_pkg_json
  native_pkg_json="$(native_package_source_dir)/package.json"
  local native_version
  native_version="$(read_package_version "$native_pkg_json")"
  if [[ "$native_version" != "$expected_core_version" ]]; then
    err "Native package version mismatch: expected $expected_core_version, got $native_version from $native_pkg_json"
    err "Rebuild native artifacts (remove --skip-build)"
    exit 1
  fi
}

verify_cache_link_target() {
  local package_pattern="$1"
  local package_name="$2"
  local expected_source="$3"

  local cache_base="$opencode_root/node_modules/.bun"
  local expected_canonical
  expected_canonical="$(canonical_dir "$expected_source")"
  local matched=0

  local cache_dir
  for cache_dir in "$cache_base"/$package_pattern; do
    [[ -d "$cache_dir" ]] || continue
    local target_dir="$cache_dir/node_modules/$package_name"

    if [[ ! -e "$target_dir" && ! -L "$target_dir" ]]; then
      err "Linked package missing in Bun cache: $target_dir"
      exit 1
    fi

    if [[ ! -L "$target_dir" ]]; then
      err "Expected symlink in Bun cache but found regular path: $target_dir"
      exit 1
    fi

    local target_canonical
    target_canonical="$(canonical_dir "$target_dir")"
    if [[ "$target_canonical" != "$expected_canonical" ]]; then
      err "Unexpected link target for $package_name"
      err "  expected: $expected_canonical"
      err "  actual:   $target_canonical"
      err "  cache:    $cache_dir"
      exit 1
    fi

    matched=$((matched + 1))
  done

  if ((matched == 0)); then
    err "No Bun cache entries found for $package_name during verification"
    exit 1
  fi
}

verify_cache_package_version() {
  local package_pattern="$1"
  local package_name="$2"
  local expected_version="$3"

  local cache_base="$opencode_root/node_modules/.bun"
  local matched=0

  local cache_dir
  for cache_dir in "$cache_base"/$package_pattern; do
    [[ -d "$cache_dir" ]] || continue
    local package_json="$cache_dir/node_modules/$package_name/package.json"
    local actual_version
    actual_version="$(read_package_version "$package_json")"

    if [[ "$actual_version" != "$expected_version" ]]; then
      err "Version mismatch for $package_name in ${cache_dir##*/}: expected $expected_version, got $actual_version"
      exit 1
    fi

    matched=$((matched + 1))
  done

  if ((matched == 0)); then
    err "No Bun cache entries found for $package_name version verification"
    exit 1
  fi
}

verify_linked_packages() {
  if $flag_dry_run; then
    step "Skipping link verification in dry-run mode"
    return 0
  fi

  local core_source=""
  local solid_source=""
  if [[ "$link_mode" == "dist" ]]; then
    core_source="$opentui_root/packages/core/dist"
    solid_source="$opentui_root/packages/solid/dist"
  else
    core_source="$opentui_root/packages/core"
    solid_source="$opentui_root/packages/solid"
  fi

  local platform arch native_pkg native_source
  read -r platform arch < <(detect_platform)
  native_pkg="@opentui/core-${platform}-${arch}"
  native_source="$opentui_root/packages/core/node_modules/${native_pkg}"

  verify_cache_link_target "@opentui+core@*" "@opentui/core" "$core_source"
  verify_cache_link_target "@opentui+solid@*" "@opentui/solid" "$solid_source"
  verify_cache_link_target "@opentui+core-${platform}-${arch}@*" "$native_pkg" "$native_source"

  verify_cache_package_version "@opentui+core@*" "@opentui/core" "$expected_core_version"
  verify_cache_package_version "@opentui+solid@*" "@opentui/solid" "$expected_solid_version"
  verify_cache_package_version "@opentui+core-${platform}-${arch}@*" "$native_pkg" "$expected_core_version"

  printf "Verified links: @opentui/core@%s, @opentui/solid@%s\n" "$expected_core_version" "$expected_solid_version" >&2
}

run_in_dir() {
  local dir="$1"
  shift
  local -a cmd=("$@")

  if $flag_dry_run; then
    printf "Would run in %s: %s\n" "$dir" "${cmd[*]}" >&2
    return 0
  fi

  info "Running in $dir: ${cmd[*]}"
  (cd "$dir" && "${cmd[@]}")
}

ensure_opentui_node_modules() {
  if [[ -d "$opentui_root/node_modules" ]]; then
    return 0
  fi

  step "Installing opentui dependencies..."
  run_in_dir "$opentui_root" bun install
}

ensure_opencode_node_modules() {
  if [[ -d "$opencode_root/node_modules/.bun" ]]; then
    return 0
  fi

  step "Installing opencode dependencies..."
  run_in_dir "$opencode_root" bun install
}

build_core_native() {
  local start=$SECONDS
  step "Building core native (zig)..."

  local -a native_args=(bun scripts/build.ts --native)
  if $flag_debug_native; then
    native_args+=(--dev)
  fi

  run_in_dir "$opentui_root/packages/core" "${native_args[@]}"
  printf "Core native built in %ss\n" "$((SECONDS - start))" >&2
}

build_core_lib() {
  local start=$SECONDS
  step "Building core library..."

  local -a args=(bun scripts/build.ts --lib)
  run_in_dir "$opentui_root/packages/core" "${args[@]}"
  printf "Core lib built in %ss\n" "$((SECONDS - start))" >&2
}

build_solid() {
  local start=$SECONDS
  step "Building solid renderer..."

  local -a args=(bun scripts/build.ts)
  run_in_dir "$opentui_root/packages/solid" "${args[@]}"
  printf "Solid built in %ss\n" "$((SECONDS - start))" >&2
}

ensure_native_for_skip_build() {
  if ! $flag_skip_build || $flag_skip_opencode; then
    return 0
  fi

  local native_src
  native_src="$(native_package_source_dir)"
  if [[ -d "$native_src" ]]; then
    info "Native package already present: $native_src"
    return 0
  fi

  step "Native package missing, building core native despite --skip-build"
  ensure_opentui_node_modules
  build_core_native
}

link_in_bun_cache() {
  local package_pattern="$1"
  local package_name="$2"
  local source_path="$3"

  local cache_base="$opencode_root/node_modules/.bun"
  local linked=0

  for cache_dir in "$cache_base"/$package_pattern; do
    [[ -d "$cache_dir" ]] || continue
    local target_dir="$cache_dir/node_modules/$package_name"
    local target_parent="${target_dir%/*}"

    if $flag_dry_run; then
      printf "Would link %s -> %s (%s)\n" "$target_dir" "$source_path" "${cache_dir##*/}" >&2
      linked=$((linked + 1))
      continue
    fi

    if [[ -e "$target_dir" || -L "$target_dir" ]]; then
      rm -rf "$target_dir"
    fi

    mkdir -p "$target_parent"
    ln -s "$source_path" "$target_dir"
    info "Linked $package_name in ${cache_dir##*/}"
    linked=$((linked + 1))
  done

  if ((linked == 0)); then
    warn "No Bun cache found for $package_name (pattern: $package_pattern)"
  fi
}

link_peer_dep() {
  local pkg_name="$1"
  local search_root="$2"
  local source=""

  if [[ -d "$search_root/node_modules/$pkg_name" ]]; then
    source="$search_root/node_modules/$pkg_name"
  else
    local pkg_dir
    for pkg_dir in "$search_root"/packages/*/node_modules/"$pkg_name"; do
      if [[ -d "$pkg_dir" ]]; then
        source="$pkg_dir"
        break
      fi
    done
  fi

  if [[ -z "$source" ]]; then
    warn "$pkg_name not found in opentui node_modules"
    return 0
  fi

  link_in_bun_cache "${pkg_name}@*" "$pkg_name" "$source"
}

validate_link_source() {
  local path="$1"
  local label="$2"
  if [[ -d "$path" ]]; then
    return 0
  fi

  if $flag_dry_run; then
    warn "$label not found (dry-run): $path"
    return 0
  fi

  err "$label not found: $path"
  exit 1
}

link_packages() {
  local core_path=""
  local solid_path=""

  if [[ "$link_mode" == "dist" ]]; then
    core_path="$opentui_root/packages/core/dist"
    solid_path="$opentui_root/packages/solid/dist"
    validate_link_source "$core_path" "Core dist"
    validate_link_source "$solid_path" "Solid dist"
  else
    core_path="$opentui_root/packages/core"
    solid_path="$opentui_root/packages/solid"
    validate_link_source "$core_path" "Core source"
    validate_link_source "$solid_path" "Solid source"
  fi

  step "Cleaning stale Bun cache entries..."
  # Remove leftover cache entries from previous workspace layouts (wt/yoga,
  # simonklee/yoga, etc.) that create extra resolution paths and cause
  # Bun.build() to bundle duplicate module copies.
  local cache_base="$opencode_root/node_modules/.bun"
  local stale_dir
  for stale_dir in "$cache_base"/*wt+yoga* "$cache_base"/*simonklee*; do
    [[ -e "$stale_dir" ]] || continue
    if $flag_dry_run; then
      printf "Would remove stale cache: %s\n" "${stale_dir##*/}" >&2
    else
      rm -rf "$stale_dir"
      info "Removed stale cache: ${stale_dir##*/}"
    fi
  done

  step "Linking @opentui/core (${link_mode})..."
  link_in_bun_cache "@opentui+core@*" "@opentui/core" "$core_path"

  step "Linking @opentui/solid (${link_mode})..."
  link_in_bun_cache "@opentui+solid@*" "@opentui/solid" "$solid_path"

  step "Linking native binary package..."
  local platform arch native_pkg native_src
  read -r platform arch < <(detect_platform)
  native_pkg="@opentui/core-${platform}-${arch}"
  native_src="$opentui_root/packages/core/node_modules/${native_pkg}"
  validate_link_source "$native_src" "Native package"
  link_in_bun_cache "@opentui+core-${platform}-${arch}@*" "$native_pkg" "$native_src"

  step "Linking peer dependencies..."
  link_peer_dep "yoga-layout" "$opentui_root"
  link_peer_dep "web-tree-sitter" "$opentui_root"
  link_peer_dep "solid-js" "$opentui_root"

  # Deduplicate shared dependencies: Bun.build() deduplicates by filesystem
  # *path*, not file identity.  When @opentui/solid/dist does
  # `import ... from "solid-js"`, Bun resolves it relative to that file — walking
  # up into opentui/packages/solid/node_modules/solid-js (a symlink into the
  # .bun cache).  Meanwhile opencode's own code resolves solid-js through
  # opencode/node_modules/.bun/solid-js@*/  which link_peer_dep pointed at the
  # hoisted copy (opentui/node_modules/solid-js).  Same files, different paths →
  # two bundled copies → broken instanceof, broken Solid context, broken Yoga
  # Node identity.
  #
  # Fix: for each shared dependency, find the canonical source that link_peer_dep
  # used (hoisted or sub-package) and repoint every other copy in opentui's
  # packages/*/node_modules/ to that same path.
  # Repoint ALL opentui workspace symlinks for @opentui/* packages to dist.
  #
  # Problem: opentui has workspace symlinks like:
  #   opentui/node_modules/@opentui/core -> ../../packages/core (source)
  #   opentui/packages/solid/node_modules/@opentui/core -> ../../../core (source)
  #
  # When @opentui/solid/dist imports "@opentui/core", Bun resolves relative to
  # the file's real location on disk (packages/solid/dist/), walking up to
  # packages/solid/node_modules/@opentui/core — hitting SOURCE.  This causes
  # yoga-layout to be bundled twice: once inlined in the dist chunk (correct)
  # and once from source (which imports yoga as a separate module).
  #
  # Fix: find and repoint every @opentui/* workspace symlink that targets a
  # source directory to its dist directory instead.
  if [[ "$link_mode" == "dist" ]]; then
    step "Repointing opentui workspace symlinks to dist..."
    local ws_link ws_real ws_dist ws_orig ws_count=0
    while IFS= read -r -d '' ws_link; do
      [[ -L "$ws_link" ]] || continue
      ws_orig="$(readlink "$ws_link")"
      # Resolve to absolute path to find the corresponding dist directory.
      ws_real="$(readlink -f "$ws_link")"
      # Skip if already pointing at a dist directory.
      [[ "$ws_real" != */dist ]] || continue
      # Only repoint if there is a dist directory to point to.
      ws_dist="$ws_real/dist"
      [[ -d "$ws_dist" ]] || continue
      if $flag_dry_run; then
        printf "Would repoint workspace %s -> %s (was %s)\n" "$ws_link" "$ws_dist" "$ws_orig" >&2
      else
        rm -f "$ws_link"
        ln -s "$ws_dist" "$ws_link"
        info "Repointed workspace $(basename "$ws_link") -> dist (was $ws_orig)"
        # Capture in array for cleanup (eval needed for dynamic function names).
        local _ws_idx=$ws_count
        eval "restore_ws_${_ws_idx}() { rm -f '$ws_link'; ln -s '$ws_orig' '$ws_link'; info 'Restored workspace symlink: $ws_link -> $ws_orig'; }"
        cleanup_register "restore_ws_${_ws_idx}"
      fi
      ws_count=$((ws_count + 1))
    done < <(find "$opentui_root" -maxdepth 5 -path "*/node_modules/@opentui/*" -print0 2>/dev/null |
      grep -z -v '/\.bun/' | grep -z -v '/dist/')
  fi

  step "Deduplicating shared dependencies..."
  local dep_name
  for dep_name in solid-js yoga-layout web-tree-sitter; do
    # Determine the canonical source: prefer the hoisted location, fall back to
    # the first sub-package copy (same logic as link_peer_dep).
    local canonical=""
    if [[ -d "$opentui_root/node_modules/$dep_name" ]]; then
      canonical="$opentui_root/node_modules/$dep_name"
    else
      local pkg_dir
      for pkg_dir in "$opentui_root"/packages/*/node_modules/"$dep_name"; do
        if [[ -d "$pkg_dir" ]]; then
          canonical="$pkg_dir"
          break
        fi
      done
    fi

    if [[ -z "$canonical" ]]; then
      info "$dep_name: not found in opentui, skipping dedup"
      continue
    fi

    local canonical_real
    canonical_real="$(readlink -f "$canonical")"

    # Repoint every sub-package copy that doesn't already resolve to the
    # canonical real path.
    while IFS= read -r -d '' dep_internal; do
      [[ -L "$dep_internal" ]] || continue
      # Skip the canonical source itself.
      [[ "$(readlink -f "$dep_internal")" != "$canonical_real" ]] || continue
      if $flag_dry_run; then
        printf "Would repoint %s -> %s\n" "$dep_internal" "$canonical" >&2
      else
        rm -f "$dep_internal"
        ln -s "$canonical" "$dep_internal"
        info "Repointed $(basename "$(dirname "$(dirname "$dep_internal")")")/$dep_name -> $(basename "$canonical") (dedup)"
      fi
    done < <(find "$opentui_root/packages" -maxdepth 3 -path "*/node_modules/$dep_name" -print0 2>/dev/null)
  done
}

build_opencode_release() {
  local start=$SECONDS
  step "Building opencode release binary..."
  local -a args=(bun run script/build.ts --single --skip-install)
  run_in_dir "$opencode_root/packages/opencode" "${args[@]}"
  printf "opencode release built in %ss\n" "$((SECONDS - start))" >&2
}

opencode_binary_path() {
  local platform arch
  read -r platform arch < <(detect_platform)

  local default_path="$opencode_root/packages/opencode/dist/opencode-${platform}-${arch}/bin/opencode"
  if [[ -e "$default_path" ]]; then
    printf "%s\n" "$default_path"
    return 0
  fi

  local candidate
  for candidate in "$opencode_root"/packages/opencode/dist/opencode-*/bin/opencode*; do
    [[ -e "$candidate" ]] || continue
    printf "%s\n" "$candidate"
    return 0
  done

  return 1
}

apply_isolated_env() {
  if ! $flag_isolated; then
    return 0
  fi

  local sandbox
  sandbox="$(mktemp -d "${TMPDIR:-/tmp}/opencode-isolated.XXXX")"
  info "Isolated config at: $sandbox"
  export XDG_CONFIG_HOME="$sandbox/config"
  export XDG_DATA_HOME="$sandbox/data"
  export XDG_CACHE_HOME="$sandbox/cache"
  export XDG_STATE_HOME="$sandbox/state"
  export OPENCODE_DISABLE_PROJECT_CONFIG=1
}

print_isolated_env() {
  local sandbox
  sandbox="$(mktemp -d "${TMPDIR:-/tmp}/opencode-isolated.XXXX")"
  printf 'export XDG_CONFIG_HOME=%s/config\n' "$sandbox"
  printf 'export XDG_DATA_HOME=%s/data\n' "$sandbox"
  printf 'export XDG_CACHE_HOME=%s/cache\n' "$sandbox"
  printf 'export XDG_STATE_HOME=%s/state\n' "$sandbox"
  printf 'export OPENCODE_DISABLE_PROJECT_CONFIG=1\n'
}

run_opencode_dev() {
  local -a args=(bun run --cwd "$opencode_root/packages/opencode" --conditions=browser src/index.ts)
  if $flag_dry_run; then
    printf "Would run: %s\n" "${args[*]}" >&2
    return 0
  fi

  exec "${args[@]}"
}

run_opencode_release_binary() {
  local binary_path=""
  if ! binary_path="$(opencode_binary_path)"; then
    err "Could not find built opencode binary under $opencode_root/packages/opencode/dist"
    exit 1
  fi

  if $flag_dry_run; then
    printf "Would run: %s\n" "$binary_path" >&2
    return 0
  fi

  exec "$binary_path"
}

now_ms() {
  local ts=""

  ts="$(date +%s%3N 2>/dev/null || true)"
  if [[ "$ts" =~ ^[0-9]+$ ]]; then
    printf "%s\n" "$ts"
    return 0
  fi

  if command -v python3 >/dev/null 2>&1; then
    ts="$(python3 -c 'import time; print(int(time.time() * 1000))' 2>/dev/null || true)"
    if [[ "$ts" =~ ^[0-9]+$ ]]; then
      printf "%s\n" "$ts"
      return 0
    fi
  fi

  ts="$(bun --eval 'console.log(Date.now())' 2>/dev/null || true)"
  if [[ "$ts" =~ ^[0-9]+$ ]]; then
    printf "%s\n" "$ts"
    return 0
  fi

  err "Unable to determine millisecond timestamp"
  exit 1
}

run_benchmark_command() {
  local label="$1"
  shift
  local -a cmd=("$@")

  step "Benchmarking ${label} (${bench_runs} runs)..."

  local run
  for ((run = 1; run <= bench_runs; run++)); do
    if $flag_dry_run; then
      printf "Would benchmark run %02d: %s\n" "$run" "${cmd[*]}" >&2
    fi
  done

  if $flag_dry_run; then
    return 0
  fi

  local -a samples=()
  local start end elapsed

  for ((run = 1; run <= bench_runs; run++)); do
    start="$(now_ms)"
    if ! "${cmd[@]}" >/dev/null 2>&1; then
      err "Benchmark run ${run} failed: ${cmd[*]}"
      exit 1
    fi
    end="$(now_ms)"
    elapsed=$((end - start))

    samples+=("$elapsed")
    printf "  run %02d: %d ms\n" "$run" "$elapsed" >&2
  done

  print_benchmark_summary "$label" "${samples[@]}"
}

print_benchmark_summary() {
  local label="$1"
  shift
  local -a samples=("$@")

  local count="${#samples[@]}"
  if ((count == 0)); then
    err "No benchmark samples collected"
    exit 1
  fi

  local sum=0
  local min=0
  local max=0
  local sample
  local idx=0
  for sample in "${samples[@]}"; do
    sum=$((sum + sample))
    if ((idx == 0 || sample < min)); then
      min=$sample
    fi
    if ((idx == 0 || sample > max)); then
      max=$sample
    fi
    idx=$((idx + 1))
  done

  local -a sorted_samples=()
  local value
  while IFS= read -r value; do
    [[ -n "$value" ]] || continue
    sorted_samples+=("$value")
  done < <(printf "%s\n" "${samples[@]}" | sort -n)

  local mean=$((sum / count))
  local median=0
  if ((count % 2 == 1)); then
    median=${sorted_samples[$((count / 2))]}
  else
    local left=${sorted_samples[$((count / 2 - 1))]}
    local right=${sorted_samples[$((count / 2))]}
    median=$(((left + right) / 2))
  fi

  local p95_rank=$(((95 * count + 99) / 100))
  if ((p95_rank < 1)); then
    p95_rank=1
  fi
  local p95=${sorted_samples[$((p95_rank - 1))]}

  echo >&2
  echo "Benchmark summary (${label}):" >&2
  printf "  runs:   %d\n" "$count" >&2
  printf "  mean:   %d ms\n" "$mean" >&2
  printf "  median: %d ms\n" "$median" >&2
  printf "  p95:    %d ms\n" "$p95" >&2
  printf "  min:    %d ms\n" "$min" >&2
  printf "  max:    %d ms\n" "$max" >&2
}

measure_tui_startup_once() {
  python3 - "$@" <<'PY'
import os
import pty
import re
import select
import signal
import subprocess
import sys
import time

if len(sys.argv) < 3:
  sys.stderr.write("usage: marker command...\n")
  sys.exit(1)

marker = sys.argv[1]
command = sys.argv[2:]
if marker not in {"tui", "tui-ready"}:
  sys.stderr.write(f"invalid marker mode: {marker}\n")
  sys.exit(1)

if not command:
  sys.stderr.write("no command provided\n")
  sys.exit(1)

CSI_RE = re.compile(rb"\x1b\[[0-?]*[ -/]*[@-~]")
OSC_RE = re.compile(rb"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)")

def strip_ansi(data: bytes) -> bytes:
  cleaned = OSC_RE.sub(b"", data)
  cleaned = CSI_RE.sub(b"", cleaned)
  return cleaned

start = time.time()
master_fd, slave_fd = pty.openpty()
proc = subprocess.Popen(command, stdin=slave_fd, stdout=slave_fd, stderr=slave_fd, close_fds=True, preexec_fn=os.setsid)
os.close(slave_fd)

data = bytearray()
deadline = start + 20.0
matched = False
elapsed_ms = None

try:
  while time.time() < deadline:
    ready, _, _ = select.select([master_fd], [], [], 0.05)
    if master_fd not in ready:
      continue

    try:
      chunk = os.read(master_fd, 8192)
    except OSError:
      break

    if not chunk:
      break

    data.extend(chunk)
    plain = strip_ansi(bytes(data))

    if marker == "tui":
      matched = b"\x1b[?1049h" in data or b"Ask anything" in plain
    else:
      matched = b"/status" in plain

    if matched:
      elapsed_ms = int((time.time() - start) * 1000)
      matched = True
      break
finally:
  try:
    os.killpg(proc.pid, signal.SIGINT)
  except ProcessLookupError:
    pass

  try:
    proc.wait(timeout=1.5)
  except Exception:
    try:
      os.killpg(proc.pid, signal.SIGKILL)
    except ProcessLookupError:
      pass
    try:
      proc.wait(timeout=1.0)
    except Exception:
      pass

if elapsed_ms is None:
  elapsed_ms = int((time.time() - start) * 1000)

if not matched:
  if marker == "tui-ready":
    sys.stderr.write("failed to detect tui ready marker (/status)\n")
  else:
    sys.stderr.write("failed to detect first tui frame\n")
  sys.exit(2)

print(elapsed_ms)
PY
}

run_benchmark_tui_command() {
  local label="$1"
  local marker="$2"
  shift 2
  local -a cmd=("$@")

  step "Benchmarking ${label} (${bench_runs} runs)..."

  local run
  for ((run = 1; run <= bench_runs; run++)); do
    if $flag_dry_run; then
      printf "Would benchmark run %02d: %s\n" "$run" "${cmd[*]}" >&2
    fi
  done

  if $flag_dry_run; then
    return 0
  fi

  local -a samples=()
  local elapsed=""
  for ((run = 1; run <= bench_runs; run++)); do
    if ! elapsed="$(measure_tui_startup_once "$marker" "${cmd[@]}")"; then
      err "Benchmark run ${run} failed: ${cmd[*]}"
      exit 1
    fi

    if [[ ! "$elapsed" =~ ^[0-9]+$ ]]; then
      err "Benchmark run ${run} returned invalid duration: $elapsed"
      exit 1
    fi

    samples+=("$elapsed")
    printf "  run %02d: %d ms\n" "$run" "$elapsed" >&2
  done

  print_benchmark_summary "$label" "${samples[@]}"
}

benchmark_opencode_release() {
  local binary_path=""
  if ! binary_path="$(opencode_binary_path)"; then
    err "Could not find built opencode binary under $opencode_root/packages/opencode/dist"
    exit 1
  fi

  if [[ "$bench_mode" == "tui" ]]; then
    run_benchmark_tui_command "opencode release first frame" "tui" "$binary_path"
    return 0
  fi

  if [[ "$bench_mode" == "tui-ready" ]]; then
    run_benchmark_tui_command "opencode release ready (/status)" "tui-ready" "$binary_path"
    return 0
  fi

  run_benchmark_command "opencode release --help" "$binary_path" "--help"
}

benchmark_opencode_dev() {
  if [[ "$bench_mode" == "tui" ]]; then
    run_benchmark_tui_command \
      "opencode dev first frame" \
      "tui" \
      bun run --cwd "$opencode_root/packages/opencode" --conditions=browser src/index.ts
    return 0
  fi

  if [[ "$bench_mode" == "tui-ready" ]]; then
    run_benchmark_tui_command \
      "opencode dev ready (/status)" \
      "tui-ready" \
      bun run --cwd "$opencode_root/packages/opencode" --conditions=browser src/index.ts
    return 0
  fi

  run_benchmark_command \
    "opencode dev --help" \
    bun run --cwd "$opencode_root/packages/opencode" --conditions=browser src/index.ts --help
}

print_done_message() {
  echo >&2
  echo "Done. To run opencode with local opentui:" >&2
  echo "  bun run --cwd $opencode_root/packages/opencode --conditions=browser src/index.ts" >&2
  echo >&2
  echo "To restore npm versions:" >&2
  echo "  bun install --cwd $opencode_root" >&2
}

main() {
  local arg
  for arg in "$@"; do
    if [[ "$arg" == "-h" || "$arg" == "--help" ]]; then
      show_usage
      exit 0
    fi
  done

  init_colors
  parse_args "$@"
  setup_traps

  if $flag_shell; then
    print_isolated_env
    return 0
  fi

  opentui_root="$(resolve_existing_dir "$opentui_root")"
  if ! $flag_skip_opencode; then
    opencode_root="$(resolve_existing_dir "$opencode_root")"
  fi

  validate_paths
  check_dependencies
  load_expected_versions

  if ! $flag_skip_build; then
    step "Phase: Build opentui"
    ensure_opentui_node_modules
    build_core_native
    if [[ "$link_mode" == "dist" ]]; then
      build_core_lib
      build_solid
    else
      step "Skipping core/solid TS builds in --source mode"
    fi
  else
    ensure_native_for_skip_build
  fi

  if $flag_skip_opencode; then
    step "Done (opencode phase skipped)"
    return 0
  fi

  step "Phase: Link into opencode"
  ensure_opencode_node_modules
  validate_local_link_artifacts
  link_packages
  step "Phase: Verify linked opentui versions"
  verify_linked_packages

  if $flag_release; then
    step "Phase: Build opencode release binary"
    build_opencode_release
    local binary_path=""
    if binary_path="$(opencode_binary_path)"; then
      echo "Release binary: $binary_path" >&2
    else
      warn "Release binary path could not be determined yet"
    fi
    apply_isolated_env
    if $flag_bench; then
      step "Phase: Benchmark opencode release startup"
      benchmark_opencode_release
    fi
    if $flag_run; then
      step "Phase: Run opencode release binary"
      run_opencode_release_binary
    fi
    return 0
  fi

  apply_isolated_env
  if $flag_bench; then
    step "Phase: Benchmark opencode dev startup"
    benchmark_opencode_dev
  fi

  if $flag_run; then
    step "Phase: Run opencode dev"
    run_opencode_dev
  fi

  print_done_message
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
