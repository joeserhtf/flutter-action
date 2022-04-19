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
  echo "$0 [-c cache/path] [-t] <channel> <version> <architecture>"
}

CACHE_PATH=""
TEST_MODE=false

if [ "$#" -eq 0 ]; then
  help_usage
  exit 0
fi

while getopts ':h:dc:' flag; do
  case "${flag}" in
  c) CACHE_PATH="$OPTARG" ;;
  d) TEST_MODE=true ;;
  h)
    help_usage
    exit 0
    ;;
  esac
done

CHANNEL="${@:$OPTIND:1}"
VERSION="${@:$OPTIND+1:1}"
ARCH="${@:$OPTIND+2:1}"

if [[ -z $CHANNEL ]] || [[ -z $VERSION ]] || [[ -z $ARCH ]]; then
  help_usage
  exit 2
fi

SDK_CACHE="$(transform_path ${CACHE_PATH})"
PUB_CACHE="$(transform_path ${CACHE_PATH}/.pub-cache)"

if [[ ! -x "${SDK_CACHE}/bin/flutter" ]]; then
  if [[ $CHANNEL == master ]]; then
    git clone -b master https://github.com/flutter/flutter.git "$SDK_CACHE"
  else
    VERSION_MANIFEST=$(get_version_manifest $TEST_MODE $CHANNEL $VERSION)

    if [[ $VERSION_MANIFEST == null ]]; then
      echo "Unable to determine Flutter version for channel: $CHANNEL version: $VERSION architecture: $ARCH"
      exit 1
    fi

    if [ "$TEST_MODE" = true ]; then
      VERSION_DEBUG=$(echo $VERSION_MANIFEST | jq -j '.channel,":",.version,":",.dart_sdk_arch')

      echo "$CHANNEL:$VERSION:$ARCH|$VERSION_DEBUG"
      echo "---"
      echo $VERSION_MANIFEST | jq
      exit 0
    else
      ARCHIVE_PATH=$(echo $VERSION_MANIFEST | jq -r '.archive')
      download_archive "$ARCHIVE_PATH" "$SDK_CACHE"
    fi
  fi
fi

echo "FLUTTER_ROOT=${SDK_CACHE}" >>$GITHUB_ENV
echo "PUB_CACHE=${PUB_CACHE}" >>$GITHUB_ENV

echo "${SDK_CACHE}/bin" >>$GITHUB_PATH
echo "${SDK_CACHE}/bin/cache/dart-sdk/bin" >>$GITHUB_PATH
echo "${PUB_CACHE}/bin" >>$GITHUB_PATH
