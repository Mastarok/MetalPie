#!/usr/bin/env bash
# Zero-sudo CommandLineTools SwiftPM environment workaround for MetalPie.
# Source this script from bash or zsh before invoking `swift build` / `swift test` / `swift run`.

if [ -n "${BASH_VERSION:-}" ]; then
  _METALPIE_SCRIPT_PATH="${BASH_SOURCE[0]}"
elif [ -n "${ZSH_VERSION:-}" ]; then
  # shellcheck disable=SC2296
  _METALPIE_SCRIPT_PATH="${(%):-%x}"
else
  _METALPIE_SCRIPT_PATH="$0"
fi

_metalpie_setup_swiftpm_env() {
  if [ -n "${ZSH_VERSION:-}" ]; then
    setopt local_options null_glob
  fi

  local script_path="$1"
  local repo_root
  repo_root="$(cd "$(dirname "$script_path")/.." && pwd)"

  local active_dev_dir
  active_dev_dir="$(xcode-select -p 2>/dev/null || true)"

  # Only apply CLT workarounds when CommandLineTools is the active developer directory
  # (full Xcode.app environments such as GitHub Actions macOS runners already ship matching
  # SwiftPM PackageDescription modules and SwiftUIMacros plugins).
  case "${active_dev_dir}" in
    *CommandLineTools*) ;;
    *) return 0 ;;
  esac

  local clt_pm_dir="/Library/Developer/CommandLineTools/usr/lib/swift/pm"
  local pm_src_dir="${active_dev_dir}/usr/lib/swift/pm"
  if [ ! -d "${pm_src_dir}/ManifestAPI" ] && [ -d "${clt_pm_dir}/ManifestAPI" ]; then
    pm_src_dir="${clt_pm_dir}"
  fi

  # Workaround A: Omit stale *.private.swiftinterface files in PackageDescription.swiftmodule
  # that cause Swift 6.4 CLT manifest compilation to link against an old PackageDescription ABI.
  local manifest_src="${pm_src_dir}/ManifestAPI"
  local pkg_desc_src="${manifest_src}/PackageDescription.swiftmodule"
  if [ -d "${pkg_desc_src}" ] && find "${pkg_desc_src}" -maxdepth 1 -name '*.private.swiftinterface' -print -quit | grep -q .; then
    local custom_libs="${repo_root}/.build/swiftpm-libs"
    local manifest_dst="${custom_libs}/ManifestAPI"
    local pkg_desc_dst="${manifest_dst}/PackageDescription.swiftmodule"
    local compiler_plugin_src="${manifest_src}/CompilerPluginSupport.swiftmodule"
    local compiler_plugin_dst="${manifest_dst}/CompilerPluginSupport.swiftmodule"
    local f=""
    local base=""

    mkdir -p "${pkg_desc_dst}"

    # Symlink libPackageDescription.dylib
    ln -sfn "${manifest_src}/libPackageDescription.dylib" "${manifest_dst}/libPackageDescription.dylib"

    # Symlink PluginAPI
    if [ -d "${pm_src_dir}/PluginAPI" ]; then
      ln -sfn "${pm_src_dir}/PluginAPI" "${custom_libs}/PluginAPI"
    fi

    # Symlink CompilerPluginSupport.swiftmodule (public interfaces + swiftdocs only)
    if [ -d "${compiler_plugin_src}" ]; then
      mkdir -p "${compiler_plugin_dst}"
      for f in "${compiler_plugin_src}"/*.swiftinterface "${compiler_plugin_src}"/*.swiftdoc; do
        [ -e "$f" ] || continue
        base="$(basename "$f")"
        case "$base" in
          *.private.swiftinterface) continue ;;
        esac
        ln -sfn "$f" "${compiler_plugin_dst}/${base}"
      done
    fi

    # Remove any previously symlinked private interfaces if present
    for f in "${pkg_desc_dst}"/*.private.swiftinterface; do
      [ -e "$f" ] && rm -f "$f"
    done

    # Symlink ONLY public *.swiftinterface and *.swiftdoc for PackageDescription
    for f in "${pkg_desc_src}"/*.swiftinterface "${pkg_desc_src}"/*.swiftdoc; do
      [ -e "$f" ] || continue
      base="$(basename "$f")"
      case "$base" in
        *.private.swiftinterface) continue ;;
      esac
      ln -sfn "$f" "${pkg_desc_dst}/${base}"
    done

    export SWIFTPM_CUSTOM_LIBS_DIR="${custom_libs}"
  fi

  # Workaround B: When using CommandLineTools without full Xcode, MacOSX27.0.sdk requires the
  # Xcode-only SwiftUIMacros compiler plugin for `@State`. Pinning SDKROOT to MacOSX26.5.sdk
  # lets standard SwiftUI `@State` compile cleanly while retaining Metal 4, MetalFX, and
  # VideoToolbox VTFrameProcessor APIs.
  if [ -z "${SDKROOT:-}" ]; then
    case "${active_dev_dir}" in
      *CommandLineTools*)
        if [ -d "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk" ]; then
          export SDKROOT="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
        fi
        ;;
    esac
  fi
}

_metalpie_setup_swiftpm_env "${_METALPIE_SCRIPT_PATH}"
unset _METALPIE_SCRIPT_PATH
unset -f _metalpie_setup_swiftpm_env
