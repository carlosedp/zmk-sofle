#!/usr/bin/env bash
#
# ZMK Firmware Local Build Script
#
# This script automates building ZMK keyboard firmware locally using containerized
# build environments (Podman/Docker). It dynamically reads build configurations from
# build.yaml and manages west dependencies from config/west.yml.
#
# Features:
#   - Automatic initialization and dependency management
#   - Dynamic configuration from YAML files (no hardcoded targets)
#   - Build all firmware or specific targets
#   - Incremental builds for faster development
#   - Clean management (build artifacts or full dependencies)
#   - Auto-generated .gitignore from west.yml
#   - Build artifact copying with timestamping
#
# Quick Start:
#   ./build_local.sh build          # Initialize (if needed) and build all firmware
#   ./build_local.sh help           # Show detailed usage
#
# Author: Generated for zmk-sofle project
# License: Same as ZMK (MIT)
#

set -euo pipefail

# Configuration
RUNTIME="${RUNTIME:-podman}" # Could be docker or podman
IMG="${ZMK_IMAGE:-docker.io/zmkfirmware/zmk-build-arm:4.1-branch}"
ENV="-e CMAKE_PREFIX_PATH=/zmk/zephyr:${CMAKE_PREFIX_PATH:-}"
COMMAND="$RUNTIME run -it --rm --workdir /zmk -v $(pwd):/zmk -v /tmp:/temp $ENV $IMG"
BUILD_CONFIG="${BUILD_CONFIG:-build.yaml}"
INCREMENTAL="${INCREMENTAL:-false}" # Set to true to skip -p (pristine) flag for faster incremental builds

log_info() {
  echo -e "\033[1;34m[INFO]\033[0m $1"
}
log_error() {
  echo -e "\033[0;31m[ERROR]\033[0m $1" >&2
}
log_warning() {
  echo -e "\033[1;33m[WARNING]\033[0m $1"
}
log_success() {
  echo -e "\033[0;32m[SUCCESS]\033[0m $1"
}

# Parse YAML file and extract build configurations
# Returns: board|shield|snippet|cmake-args|artifact-name for each build
parse_build_config() {
  if [ ! -f "$BUILD_CONFIG" ]; then
    log_error "Build configuration file not found: $BUILD_CONFIG"
    exit 1
  fi

  # Simple YAML parser that extracts build configurations
  # This avoids external dependencies like yq
  local in_include=0
  local board="" shield="" snippet="" cmake_args="" artifact_name=""

  while IFS= read -r line; do
    # Skip comments and empty lines
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// /}" ]] && continue

    # Check if we're in the include section
    if [[ "$line" =~ ^include: ]]; then
      in_include=1
      continue
    fi

    if [ $in_include -eq 1 ]; then
      # New item starts with "- board:"
      if [[ "$line" =~ ^[[:space:]]*-[[:space:]]+board:[[:space:]]*(.+) ]]; then
        # Output previous config if exists
        if [ -n "$board" ]; then
          echo "${board}|${shield}|${snippet}|${cmake_args}|${artifact_name}"
        fi
        # Start new config
        board="${BASH_REMATCH[1]}"
        shield=""
        snippet=""
        cmake_args=""
        artifact_name=""
      elif [[ "$line" =~ ^[[:space:]]+shield:[[:space:]]*(.+) ]]; then
        shield="${BASH_REMATCH[1]}"
      elif [[ "$line" =~ ^[[:space:]]+snippet:[[:space:]]*(.+) ]]; then
        snippet="${BASH_REMATCH[1]}"
      elif [[ "$line" =~ ^[[:space:]]+cmake-args:[[:space:]]*(.+) ]]; then
        cmake_args="${BASH_REMATCH[1]}"
      elif [[ "$line" =~ ^[[:space:]]+artifact-name:[[:space:]]*(.+) ]]; then
        artifact_name="${BASH_REMATCH[1]}"
      fi
    fi
  done <"$BUILD_CONFIG"

  # Output last config
  if [ -n "$board" ]; then
    echo "${board}|${shield}|${snippet}|${cmake_args}|${artifact_name}"
  fi
}

# Parse west.yml and extract project names (these become directories)
parse_west_projects() {
  local west_file="${1:-config/west.yml}"

  if [ ! -f "$west_file" ]; then
    log_error "West manifest file not found: $west_file"
    exit 1
  fi

  local in_projects=0

  while IFS= read -r line; do
    # Skip comments and empty lines
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// /}" ]] && continue

    # Check if we're in the projects section
    if [[ "$line" =~ ^[[:space:]]*projects: ]]; then
      in_projects=1
      continue
    fi

    # Exit projects section when we hit another top-level key
    if [ $in_projects -eq 1 ] && [[ "$line" =~ ^[[:space:]]*[a-z]+:[[:space:]]*$ ]] && [[ ! "$line" =~ ^[[:space:]]*- ]]; then
      break
    fi

    if [ $in_projects -eq 1 ]; then
      # Extract project name
      if [[ "$line" =~ ^[[:space:]]*-[[:space:]]+name:[[:space:]]*(.+) ]]; then
        echo "${BASH_REMATCH[1]}"
      elif [[ "$line" =~ ^[[:space:]]+name:[[:space:]]*(.+) ]]; then
        echo "${BASH_REMATCH[1]}"
      fi
    fi
  done <"$west_file"
}

# Check if Docker image is available locally, pull if needed
check_image() {
  if ! $RUNTIME image inspect "$IMG" &>/dev/null; then
    log_warning "Image $IMG not found locally. Pulling..."
    $RUNTIME pull "$IMG"
    log_success "Image pulled successfully"
  fi
}

# Build a specific firmware target from YAML config
build_target() {
  local target_name="$1"
  check_init
  check_image

  local start_time
  start_time=$(date +%s)

  local found=0
  while IFS='|' read -r board shield snippet cmake_args artifact_name; do
    if [ "$artifact_name" = "$target_name" ]; then
      found=1
      log_info "Building ${artifact_name} firmware..."

      # Build the command arguments
      local build_args=()
      build_args+=("-d" "./build/${artifact_name}")

      # Add pristine flag unless incremental build is enabled
      if [ "$INCREMENTAL" != "true" ]; then
        build_args+=("-p")
      fi

      build_args+=("-b" "$board")
      build_args+=("-s" "/zmk/zmk/app")

      # Add snippet if specified
      if [ -n "$snippet" ]; then
        build_args+=("-S" "$snippet")
      fi

      # Add shield and cmake-args to cmake arguments
      local cmake_args_array=()
      cmake_args_array+=("-DZMK_CONFIG=/zmk/config")
      if [ -n "$shield" ]; then
        cmake_args_array+=("-DSHIELD=$shield")
      fi
      if [ -n "$cmake_args" ]; then
        # Split cmake_args by spaces and add to array
        read -ra extra_args <<<"$cmake_args"
        cmake_args_array+=("${extra_args[@]}")
      fi

      # Execute build
      $COMMAND west build "${build_args[@]}" -- "${cmake_args_array[@]}"

      check_build_artifact "./build/${artifact_name}/zephyr/zmk.uf2" "${artifact_name} build"

      local end_time
      end_time=$(date +%s)
      local duration=$((end_time - start_time))
      log_success "Build completed in ${duration}s"
      break
    fi
  done < <(parse_build_config)

  if [ $found -eq 0 ]; then
    log_error "Target '$target_name' not found in $BUILD_CONFIG"
    return 1
  fi
}

# Check if the container runtime is available
if ! command -v "$RUNTIME" &>/dev/null; then
  log_error "Error: $RUNTIME could not be found. Please install it to proceed."
  exit 1
fi

# Initialize the repo
init() {
  log_info "Initializing repository..."
  $COMMAND west init -l config
  $COMMAND west update
  log_info "Initialization complete."
}

# Update the repo
update() {
  log_info "Updating repository..."
  $COMMAND west update
  log_info "Update complete."
}

check_init() {
  local needs_init=0

  # Check if .west directory exists (indicates west init has been run)
  if [ ! -d "./.west" ]; then
    log_warning "West workspace not initialized (.west/ not found)"
    needs_init=1
  fi

  # Check if zephyr directory exists
  if [ ! -d "./zephyr" ]; then
    log_warning "Zephyr SDK not found (zephyr/ not found)"
    needs_init=1
  fi

  # Check if main zmk project exists
  if [ ! -d "./zmk" ]; then
    log_warning "ZMK firmware not found (zmk/ not found)"
    needs_init=1
  fi

  # If any critical directory is missing, initialize
  if [ $needs_init -eq 1 ]; then
    log_warning "Repository not initialized. Running initialization..."
    init
    return 0
  fi

  # Check if all west projects from config/west.yml are present
  local missing_projects=()
  while IFS= read -r project_name; do
    if [ ! -d "./${project_name}" ]; then
      missing_projects+=("$project_name")
    fi
  done < <(parse_west_projects)

  # If any projects are missing, run update
  if [ ${#missing_projects[@]} -gt 0 ]; then
    log_warning "Missing west projects: ${missing_projects[*]}"
    log_info "Running west update to fetch missing projects..."
    update
  fi
}

# Verify build artifact exists
check_build_artifact() {
  local artifact_path="$1"
  local build_name="$2"

  if [ -f "$artifact_path" ]; then
    log_info "✓ $build_name successful: $artifact_path"
    return 0
  else
    log_error "✗ $build_name failed: Artifact not found at $artifact_path"
    return 1
  fi
}

# Build the firmware
build_dongle() {
  build_target "eyelash_sofle_central_dongle_oled"
}

build_left() {
  build_target "eyelash_sofle_peripheral_left"
}

build_central_left() {
  build_target "eyelash_sofle_central_left"
}

build_right() {
  build_target "eyelash_sofle_peripheral_right"
}

build_reset() {
  build_target "settings_reset"
}

build() {
  local failed=0
  local start_time
  start_time=$(date +%s)

  # Build all targets from YAML config
  while IFS='|' read -r board shield snippet cmake_args artifact_name; do
    build_target "$artifact_name" || failed=$((failed + 1))
  done < <(parse_build_config)

  local end_time
  end_time=$(date +%s)
  local duration=$((end_time - start_time))

  echo ""
  if [ $failed -eq 0 ]; then
    log_info "========================================"
    log_success "All builds completed successfully in ${duration}s!"
    log_info "========================================"
  else
    log_error "========================================"
    log_error "Build completed with $failed failure(s) in ${duration}s"
    log_error "========================================"
    exit 1
  fi
}

# List all available build targets from YAML
list_targets() {
  log_info "Available build targets from $BUILD_CONFIG:"
  echo ""
  while IFS='|' read -r board shield snippet cmake_args artifact_name; do
    echo "  - $artifact_name"
    echo "      board: $board"
    [ -n "$shield" ] && echo "      shield: $shield"
    [ -n "$snippet" ] && echo "      snippet: $snippet"
    [ -n "$cmake_args" ] && echo "      cmake-args: $cmake_args"
    echo ""
  done < <(parse_build_config)
}

# Clean build artifacts
clean() {
  local target="${1:-}"

  if [ -n "$target" ]; then
    # Clean specific target
    if [ -d "./build/${target}" ]; then
      log_info "Cleaning build directory for ${target}..."
      rm -rf "./build/${target}"
      log_success "Cleaned ./build/${target}"
    else
      log_warning "Build directory ./build/${target} does not exist"
    fi
  else
    # Clean all
    if [ -d "./build" ]; then
      log_info "Cleaning all build directories..."
      rm -rf ./build
      log_success "Cleaned ./build directory"
    else
      log_warning "Build directory does not exist"
    fi
  fi
}

# Clean all west-managed dependencies and build artifacts
clean_all() {
  log_warning "This will remove all west-managed dependencies and build artifacts"
  read -p "Are you sure? (y/N) " -n 1 -r
  echo

  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log_info "Clean cancelled"
    return 0
  fi

  log_info "Cleaning build directory..."
  [ -d "./build" ] && rm -rf ./build

  log_info "Cleaning west-managed projects from config/west.yml..."
  while IFS= read -r project_name; do
    if [ -d "./${project_name}" ]; then
      log_info "Removing ${project_name}/"
      rm -rf "./${project_name}"
    fi
  done < <(parse_west_projects)

  # Also clean common west directories
  [ -d "./modules" ] && rm -rf ./modules && log_info "Removed modules/"
  [ -d "./tools" ] && rm -rf ./tools && log_info "Removed tools/"
  [ -d "./.west" ] && rm -rf ./.west && log_info "Removed .west/"

  log_success "All dependencies and build artifacts cleaned"
  log_info "Run './build_local.sh init' to reinitialize"
}

# Generate/update .gitignore based on west.yml
update_gitignore() {
  log_info "Generating .gitignore from config/west.yml..."

  local gitignore_file=".gitignore"
  local temp_file="${gitignore_file}.tmp"

  # Start with basic ignores
  cat >"$temp_file" <<'EOF'
# Build artifacts
build/
artifacts/

# ZMK
zephyr/
!zephyr/module.yml

# West managed directories
.west/
modules/
tools/

# West projects from config/west.yml
EOF

  # Add project directories from west.yml
  while IFS= read -r project_name; do
    echo "${project_name}/" >>"$temp_file"
  done < <(parse_west_projects)

  # Move temp file to actual gitignore
  mv "$temp_file" "$gitignore_file"
  log_success "Updated .gitignore with $(wc -l <"$gitignore_file") entries"
}

# Copy build artifacts to a defined directory
copy_artifacts() {
  DEST="${1:-./artifacts}"
  mkdir -p "$DEST"
  local copied=0

  # Copy all artifacts from YAML config
  while IFS='|' read -r board shield snippet cmake_args artifact_name; do
    local src_file="./build/${artifact_name}/zephyr/zmk.uf2"
    local dst_file="$DEST/${artifact_name}.uf2"

    if [ -f "$src_file" ]; then
      cp "$src_file" "$dst_file"
      log_info "Copied $artifact_name to $dst_file"
      copied=$((copied + 1))
    else
      log_warning "Artifact not found: $src_file (skipping)"
    fi
  done < <(parse_build_config)

  if [ $copied -gt 0 ]; then
    log_success "$copied artifact(s) copied to $DEST directory."
  else
    log_warning "No artifacts found to copy"
  fi
}

show_help() {
  cat <<EOF
ZMK Firmware Local Build Script Using Containerized Environment

The script allows you to build ZMK firmware targets defined in a YAML configuration file without the need to install all build dependencies locally. It uses a container runtime (Podman or Docker) to run the build environment.

Usage: $0 [flags] <command>

Commands:
  init             Initialize the repository (west init + update)
  update           Update the repository (west update)
  list             List all available build targets from build.yaml
  build_dongle     Build central dongle firmware
  build_left       Build peripheral left firmware
  build_right      Build peripheral right firmware
  build_central_left Build central left (no dongle) firmware
  build_reset      Build settings reset firmware
  build [name]     Build all firmware or specific target by name
  clean [target]   Clean build directory (all or specific target)
  clean_all        Clean all west dependencies and build artifacts
  gitignore        Generate/update .gitignore from config/west.yml
  copy [dest]      Copy build artifacts to directory (default: ./artifacts)
  help             Show this help message

Environment Variables:
  RUNTIME       Container runtime (default: podman, can be docker)
  ZMK_IMAGE     ZMK build image (default: docker.io/zmkfirmware/zmk-build-arm:4.1-branch)
  BUILD_CONFIG  Build configuration file (default: build.yaml)
  INCREMENTAL   Skip pristine builds for faster rebuilds (default: false)

Examples:
  $0 build                                      # Build all firmware from build.yaml
  $0 build eyelash_sofle_peripheral_left        # Build specific target
  $0 list                                       # List all available targets
  $0 build_dongle                               # Build central dongle
  $0 build_left                                 # Build peripheral left
  $0 build_central_left                         # Build central left (no dongle)
  $0 clean                                      # Clean build artifacts
  $0 clean eyelash_sofle_peripheral_left        # Clean specific target
  $0 clean_all                       # Clean all west dependencies
  $0 gitignore                       # Update .gitignore from west.yml
  $0 copy                            # Copy artifacts to ./artifacts
  $0 copy /path/to/dir               # Copy artifacts to custom directory
  INCREMENTAL=true $0 build_left     # Faster incremental build
  BUILD_CONFIG=custom.yaml $0 build  # Use custom build config
  RUNTIME=docker $0 build            # Use docker instead of podman

EOF
}

# Check if an argument was provided
if [ $# -eq 0 ]; then
  log_error "Error: No command provided"
  echo ""
  show_help
  exit 1
fi

# Parse flags
INCREMENTAL_FLAG=""
ARGS=()
while [[ $# -gt 0 ]]; do
  case $1 in
  -i | --incremental)
    INCREMENTAL_FLAG="true"
    shift
    ;;
  *)
    ARGS+=("$1")
    shift
    ;;
  esac
done

# Set incremental mode if flag was provided
if [ -n "$INCREMENTAL_FLAG" ]; then
  INCREMENTAL="true"
fi

# Restore positional parameters
set -- "${ARGS[@]}"

case "$1" in
init)
  init
  ;;
update)
  update
  ;;
list)
  list_targets
  ;;
build_dongle)
  build_dongle
  ;;
build_left)
  build_left
  ;;
build_right)
  build_right
  ;;
build_central_left)
  build_central_left
  ;;
build_reset)
  build_reset
  ;;
build)
  # If second argument provided, build specific target
  if [ -n "${2:-}" ]; then
    build_target "$2"
  else
    build
  fi
  ;;
clean)
  clean "${2:-}"
  ;;
clean_all)
  clean_all
  ;;
gitignore)
  update_gitignore
  ;;
copy)
  copy_artifacts "${2:-}"
  ;;
help | --help | -h)
  show_help
  ;;
*)
  log_error "Error: Unknown command '$1'"
  echo ""
  show_help
  exit 1
  ;;
esac
