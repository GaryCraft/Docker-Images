#!/bin/bash
cd /home/container

to_lower() {
  echo "$1" | tr '[:upper:]' '[:lower:]'
}

is_true() {
  case "$(to_lower "$1")" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

clean_container_dir() {
  find /home/container -mindepth 1 -maxdepth 1 \
    ! -name '.nvm' \
    ! -name '.cache' \
    ! -name '.release_tmp' \
    -exec rm -rf {} +
}

get_latest_release_tag() {
  local repo_path="$1"
  local api_url="https://api.github.com/repos/${repo_path}/releases/latest"
  local auth_header=""

  if [ -n "${ACCESS_TOKEN}" ]; then
    auth_header="Authorization: Bearer ${ACCESS_TOKEN}"
  fi

  if [ -n "${auth_header}" ]; then
    curl -fsSL -H "${auth_header}" "${api_url}" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1
  else
    curl -fsSL "${api_url}" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1
  fi
}

url_encode() {
  local string="$1"
  if command -v jq &> /dev/null; then
    printf %s "$string" | jq -sRr @uri
  else
    # Pure bash fallback for URL encoding
    local i="${#string}"
    while [ $((i -= 1)) -ge 0 ]; do
      printf '%s' "${string:$i:1}" | sed 's/[^a-zA-Z0-9._-]/\\x&/g' | tr \\ %
    done
  fi
}

get_release_asset_url() {
  local repo_path="$1"
  local release_tag="$2"
  local asset_pattern="${3:-\\.tar\\.gz$|\\.zip$}"
  local api_url="https://api.github.com/repos/${repo_path}/releases/tags/${release_tag}"
  local auth_header=""

  if [ -n "${ACCESS_TOKEN}" ]; then
    auth_header="Authorization: Bearer ${ACCESS_TOKEN}"
  fi

  if command -v jq &> /dev/null; then
    if [ -n "${auth_header}" ]; then
      curl -fsSL -H "${auth_header}" "${api_url}" | jq -r --arg pattern "${asset_pattern}" '.assets[] | select(.name | test($pattern)) | .url' | head -n1
    else
      curl -fsSL "${api_url}" | jq -r --arg pattern "${asset_pattern}" '.assets[] | select(.name | test($pattern)) | .url' | head -n1
    fi
  else
    if [ -n "${auth_header}" ]; then
      curl -fsSL -H "${auth_header}" "${api_url}" | grep -oP '"url": "\Khttps://api\.github\.com/repos/[^"]+/releases/assets/[^"]+' | head -n1
    else
      curl -fsSL "${api_url}" | grep -oP '"url": "\Khttps://api\.github\.com/repos/[^"]+/releases/assets/[^"]+' | head -n1
    fi
  fi
}

# Make internal Docker IP address available to processes.
export INTERNAL_IP=$(ip route get 1 | awk '{print $NF;exit}')

#Splitting {{_ENV_STRING}}
line="${_ENV_STRING}"
arr=($line)
for i in "${arr[@]}"
do
  echo "Exporting Variable $i"
	export $i
done

## add git ending if it's not on the address
if [[ ${GIT_ADDRESS} != *.git ]]; then
    GIT_ADDRESS=${GIT_ADDRESS}.git
fi

GIT_MODE="$(to_lower "${GIT_MODE:-repo}")"
ALWAYS_INSTALL_AND_BUILD="${ALWAYS_INSTALL_AND_BUILD:-false}"
# Default BRANCH_TAG depending on GIT_MODE: 'main' for repo, 'latest' for release
if [ "${GIT_MODE}" = "release" ]; then
  BRANCH_TAG="${BRANCH_TAG:-${BRANCH:-latest}}"
else
  BRANCH_TAG="${BRANCH_TAG:-${BRANCH:-main}}"
fi
SKIP_INSTALL_AND_BUILD=0
SOURCE_CHANGED=0

if [ -z "${USERNAME}" ] && [ -z "${ACCESS_TOKEN}" ]; then
  echo -e "using anon api call"
  AUTH_GIT_ADDRESS="${GIT_ADDRESS}"
else
  AUTH_GIT_ADDRESS="https://${USERNAME}:${ACCESS_TOKEN}@${GIT_ADDRESS#*://}"
fi

## If using github, login to github cli
#if [[ ${GIT_ADDRESS} == *"github.com"* ]]; then
#	echo "Logging into GitHub CLI"
#	gh auth login --with-token < <(echo -e ${ACCESS_TOKEN})
#fi


if [ "${GIT_MODE}" = "release" ]; then
  RELEASE_TMP_DIR="/home/container/.release_tmp"
  RELEASE_ARCHIVE="${RELEASE_TMP_DIR}/release.tar.gz"

  REPO_PATH="${GIT_ADDRESS#*://}"
  REPO_PATH="${REPO_PATH#*@}"
  REPO_PATH="${REPO_PATH#github.com/}"
  REPO_PATH="${REPO_PATH%.git}"

  if [[ "${REPO_PATH}" != */* ]]; then
    echo "Invalid github repository path for release mode: ${REPO_PATH}"
    exit 1
  fi

  echo "Extracted repo path: ${REPO_PATH}"

  if [ "${BRANCH_TAG}" = "latest" ]; then
    BRANCH_TAG="$(get_latest_release_tag "${REPO_PATH}")"
    if [ -z "${BRANCH_TAG}" ]; then
      echo "Unable to resolve latest release tag for ${REPO_PATH}"
      exit 1
    fi
    echo "Resolved latest release tag: ${BRANCH_TAG}"
  fi

  echo "Release tag: ${BRANCH_TAG}"

  echo "Downloading release archive from GitHub API"
  mkdir -p "${RELEASE_TMP_DIR}"

  # Get the release asset download URL from GitHub releases
  RELEASE_ASSET_URL="$(get_release_asset_url "${REPO_PATH}" "${BRANCH_TAG}")"
  
  if [ -z "${RELEASE_ASSET_URL}" ]; then
    echo "Failed to find release assets for ${REPO_PATH}/${BRANCH_TAG}"
    exit 1
  fi
  
  echo "Downloading from: ${RELEASE_ASSET_URL}"
  
  if [ -n "${ACCESS_TOKEN}" ]; then
    if ! curl -fL -H "Authorization: Bearer ${ACCESS_TOKEN}" -H "Accept: application/octet-stream" "${RELEASE_ASSET_URL}" -o "${RELEASE_ARCHIVE}"; then
      echo "Failed to download release asset"
      exit 1
    fi
  else
    if ! curl -fL -H "Accept: application/octet-stream" "${RELEASE_ASSET_URL}" -o "${RELEASE_ARCHIVE}"; then
      echo "Failed to download release asset"
      exit 1
    fi
  fi

  clean_container_dir
  mkdir -p "${RELEASE_TMP_DIR}"

  echo "Extracting release archive"
  if ! tar -xzf "${RELEASE_ARCHIVE}" -C "${RELEASE_TMP_DIR}"; then
    echo "Failed to extract release archive"
    rm -f "${RELEASE_ARCHIVE}"
    exit 1
  fi

  RELEASE_DIR="$(tar -tzf "${RELEASE_ARCHIVE}" | head -1 | cut -d/ -f1)"
  if [ -z "${RELEASE_DIR}" ] || [ ! -d "${RELEASE_TMP_DIR}/${RELEASE_DIR}" ]; then
    echo "Invalid extracted release directory"
    rm -f "${RELEASE_ARCHIVE}"
    exit 1
  fi

  cp -a "${RELEASE_TMP_DIR}/${RELEASE_DIR}/." /home/container/
  rm -rf "${RELEASE_TMP_DIR}"

  SKIP_INSTALL_AND_BUILD=1
  echo "Release downloaded and extracted"
else
  if [ ! -d "/home/container/.git" ]; then
    echo "Repository Missing"
    echo "Cloning repository..."
    if [ "${BRANCH_TAG}" = "latest" ]; then
      echo "Using default branch"
      git clone ${AUTH_GIT_ADDRESS} /home/container
    else
      echo "Using branch: ${BRANCH_TAG}"
      git clone -b ${BRANCH_TAG} ${AUTH_GIT_ADDRESS} /home/container
    fi
    SOURCE_CHANGED=1
    echo "Cloned repository"
  else
    echo "Updating repository..."
    PREVIOUS_COMMIT=$(git rev-parse HEAD 2>/dev/null || true)

    if [ "${BRANCH_TAG}" = "latest" ]; then
      git pull
    else
      echo "Checking out branch: ${BRANCH_TAG}"
      git fetch
      git checkout ${BRANCH_TAG}
      git pull
    fi

    CURRENT_COMMIT=$(git rev-parse HEAD 2>/dev/null || true)
    if [ "${PREVIOUS_COMMIT}" != "${CURRENT_COMMIT}" ]; then
      SOURCE_CHANGED=1
      rm -rf ./dist
      echo "Repository updated: ${PREVIOUS_COMMIT} -> ${CURRENT_COMMIT}"
    else
      echo "No repository changes detected"
    fi
  fi

  # If Git submodules are present, initialize them
  if [ -f /home/container/.gitmodules ]; then
    echo "Initializing submodules"
    git submodule init
    git submodule update
    echo "Initialized submodules"
  fi
fi

# Check for NODE_VERSION environment variable, if not set, default to 16
if [ -z "$NODE_VERSION" ]; then
	NODE_VERSION=18
fi

# If .nvm directory does not exist, copy it from /usr/local/nvm
if [ ! -d "/home/container/.nvm" ]; then
	cp -r /usr/local/nvm /home/container/.nvm
fi

# Load NVM
export NVM_DIR="/home/container/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

# Use NVM to install the specified Node.js version and set it as the default
nvm install $NODE_VERSION
nvm alias default $NODE_VERSION
nvm use $NODE_VERSION

# Print Node.js Version
echo "Node.js Version: "
node -v
# Update NPM
npm -g install npm@latest

if [ -f /home/container/package.json ]; then
  if [ "${SKIP_INSTALL_AND_BUILD}" -eq 0 ]; then
    if is_true "${ALWAYS_INSTALL_AND_BUILD}" || [ "${SOURCE_CHANGED}" -eq 1 ] || [ ! -d /home/container/node_modules ]; then
      echo "Installing node_modules"
      npm install
      echo "Installed node_modules"
    else
      echo "Skipping npm install (no source changes detected)"
    fi

    if is_true "${ALWAYS_INSTALL_AND_BUILD}" || [ "${SOURCE_CHANGED}" -eq 1 ] || [ ! -d /home/container/dist ]; then
      echo "Building application"
      npm run build
      echo "Built application"
    else
      echo "Skipping npm build (no source changes detected)"
    fi
  else
    echo "Skipping npm install and build (release mode)"
  fi
fi

# Replace Startup Variables
MODIFIED_STARTUP=$(echo -e ${STARTUP} | sed -e 's/{{/${/g' -e 's/}}/}/g')
echo ":/home/container$ ${MODIFIED_STARTUP}"

# Run the Server
eval ${MODIFIED_STARTUP}