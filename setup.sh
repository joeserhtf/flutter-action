#!/bin/bash

OS_NAME=$(echo "$RUNNER_OS" | awk '{print tolower($0)}')
MANIFEST_BASE_URL="https://storage.googleapis.com/flutter_infra_release/releases"
MANIFEST_URL="${MANIFEST_BASE_URL}/releases_${OS_NAME}.json"
MANIFEST_TEST_PATH="test/releases_${OS_NAME}.json"

# convert version like 2.5.x to 2.5
normalize_version() {
  if [[ $1 == *x ]]; then
    echo ${1::-2}
  else
    echo $1
  fi
}

latest_version() {
  jq --arg channel "$1" --arg arch "$ARCH" '.releases | map(select(.channel==$channel) | select(.dart_sdk_arch == null or .dart_sdk_arch == $arch)) | first'
}

wildcard_version() {
  if [ $2 == *"v"* ]; then # is legacy version format
    if [[ $1 == any ]]; then
      jq --arg version "$2" '.releases | map(select(.version | startswith($version) )) | first'
    else
      jq --arg channel "$1" --arg version "$2" '.releases | map(select(.channel==$channel) | select(.version | startswith($version) )) | first'
    fi
  elif [[ $1 == any ]]; then
    jq --arg version "$2" --arg arch "$ARCH" '.releases | map(select(.version | startswith($version)) | select(.dart_sdk_arch == null or .dart_sdk_arch == $arch)) | first'
  else
    jq --arg channel "$1" --arg version "$2" --arg arch "$ARCH" '.releases | map(select(.channel==$channel) | select(.version | startswith($version) ) | select(.dart_sdk_arch == null or .dart_sdk_arch == $arch)) | first'
  fi
}

get_version() {
  if [[ $2 == any ]]; then
    latest_version $1
  else
    wildcard_version $1 $2
  fi
}

get_release_manifest() {
  if [ "$1" = true ]; then
    cat $MANIFEST_TEST_PATH
  else
    curl --silent --connect-timeout 15 --retry 5 $MANIFEST_URL
  fi
}

get_version_manifest() {
  release_manifest=$(get_release_manifest $1)
  version_manifest=$(echo $release_manifest | get_version $2 $(normalize_version $3))

  if [[ $version_manifest == null ]]; then
    # fallback through legacy version format
    echo $releases_manifest | wildcard_version $2 "v$(normalize_version $3)"
  else
    echo $version_manifest
  fi
}

download_archive() {
  archive_url="$MANIFEST_BASE_URL/$1"
  archive_name=$(basename $1)
  archive_local="$RUNNER_TEMP/$archive_name"

  curl --connect-timeout 15 --retry 5 $archive_url >$archive_local

  # Create the target folder
  mkdir -p "$2"

  if [[ $archive_name == *zip ]]; then
    unzip -q -o "$archive_local" -d "$RUNNER_TEMP"
    # Remove the folder again so that the move command can do a simple rename
    # instead of moving the content into the target folder.
    # This is a little bit of a hack since the "mv --no-target-directory"
    # linux option is not available here
    rm -r "$2"
    mv ${RUNNER_TEMP}/flutter "$2"
  else
    tar xf "$archive_local" -C "$2" --strip-components=1
  fi

  rm $archive_local
}

transform_path() {
  if [[ $OS_NAME == windows ]]; then
    echo $1 | sed -e 's/^\///' -e 's/\//\\/g'
  else
    echo $1
  fi
}

help_usage() {
  echo "USAGE:"
  echo "$0 [-c cache/path] [-t] [channel] [version] [architecture]"
  echo ""
  echo "EXAMPLES:"
  echo "$0                # download latest stable version"
  echo "$0 stable         # download latest beta version"
  echo "$0 beta           # download latest beta version"
  echo "$0 master         # download mater version"
  echo "$0 any            # download latest version in any channel"
  echo "$0 stable 2.2     # download 2.2.x version from stable channel"
  echo "$0 stable 2.2.x   # download 2.2.x version from stable channel"
  echo "$0 beta 2 arm64   # download 2.x version from beta channel with arm64 architecture"
  echo "$0 -c /tmp beta   # download latest beta version and cache it to /tmp"
  echo "$0 -t             # display latest stable version (not download)"
}

not_found_error() {
  echo "Unable to determine Flutter version for channel: $1 version: $2 architecture: $3"
}

CACHE_PATH=""
TEST_MODE=false
TEST_EXPECTED=""

while getopts 'htc:x:' flag; do
  case "${flag}" in
  c) CACHE_PATH="$OPTARG" ;;
  t) TEST_MODE=true ;;
  x) TEST_EXPECTED="$OPTARG" ;;
  h)
    help_usage
    exit 0
    ;;
  *)
    echo ""
    help_usage
    exit 1
    ;;
  esac
done

CHANNEL="${@:$OPTIND:1}"
VERSION="${@:$OPTIND+1:1}"
ARCH="${@:$OPTIND+2:1}"

# default values
[[ -z $CHANNEL ]] && CHANNEL=stable
[[ -z $VERSION ]] && VERSION=any
[[ -z $ARCH ]] && ARCH=x64

test_assert() {
  echo "${1}" | head -n 1 | awk -F'|' '{print $2}' | grep "^${2}$"
  echo $?
}

SDK_CACHE="$(transform_path ${CACHE_PATH})"
PUB_CACHE="$(transform_path ${CACHE_PATH}/.pub-cache)"

if [ "$TEST_MODE" = true ]; then
  if [[ $CHANNEL == master ]]; then
    echo "master:master"
    exit 0
  else
    VERSION_MANIFEST=$(get_version_manifest $TEST_MODE $CHANNEL $VERSION)

    if [[ $VERSION_MANIFEST == null ]]; then
      not_found_error $CHANNEL $VERSION $ARCH
      exit 1
    fi

    VERSION_DEBUG=$(echo $VERSION_MANIFEST | jq -j '.channel,":",.version,":",.dart_sdk_arch')

    echo "$CHANNEL:$VERSION:$ARCH|$VERSION_DEBUG"
    echo "---"
    echo $VERSION_MANIFEST | jq
    echo $VERSION_DEBUG | grep -q "^${TEST_EXPECTED}$"
    exit $?
  fi
fi

if [[ ! -x "${SDK_CACHE}/bin/flutter" ]]; then
  if [[ $CHANNEL == master ]]; then
    git clone -b master https://github.com/flutter/flutter.git "$SDK_CACHE"
  else
    VERSION_MANIFEST=$(get_version_manifest $TEST_MODE $CHANNEL $VERSION)

    if [[ $VERSION_MANIFEST == null ]]; then
      not_found_error $CHANNEL $VERSION $ARCH
      exit 1
    fi

    ARCHIVE_PATH=$(echo $VERSION_MANIFEST | jq -r '.archive')
    download_archive "$ARCHIVE_PATH" "$SDK_CACHE"
  fi
fi

echo "FLUTTER_ROOT=${SDK_CACHE}" >>$GITHUB_ENV
echo "PUB_CACHE=${PUB_CACHE}" >>$GITHUB_ENV

echo "${SDK_CACHE}/bin" >>$GITHUB_PATH
echo "${SDK_CACHE}/bin/cache/dart-sdk/bin" >>$GITHUB_PATH
echo "${PUB_CACHE}/bin" >>$GITHUB_PATH
