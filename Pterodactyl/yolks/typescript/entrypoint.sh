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
    -exec rm -rf {} +
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
  RELEASE_TAG="${RELEASE_TAG:-latest}"
  RELEASE_ARCHIVE="/tmp/release.tar.gz"

  REPO_PATH="${GIT_ADDRESS#*://}"
  REPO_PATH="${REPO_PATH#*@}"
  REPO_PATH="${REPO_PATH#github.com/}"
  REPO_PATH="${REPO_PATH%.git}"

  if [[ "${REPO_PATH}" != */* ]]; then
    echo "Invalid github repository path for release mode: ${REPO_PATH}"
    exit 1
  fi

  if [ "${RELEASE_TAG}" = "latest" ]; then
    RELEASE_URL="https://github.com/${REPO_PATH}/archive/refs/tags/$(curl -fsSL https://api.github.com/repos/${REPO_PATH}/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/').tar.gz"
  else
    RELEASE_URL="https://github.com/${REPO_PATH}/archive/refs/tags/${RELEASE_TAG}.tar.gz"
  fi

  echo "Downloading release archive from ${RELEASE_URL}"
  curl -fL "${RELEASE_URL}" -o "${RELEASE_ARCHIVE}"

  clean_container_dir

  echo "Extracting release archive"
  tar -xzf "${RELEASE_ARCHIVE}" -C /tmp
  RELEASE_DIR="$(tar -tzf "${RELEASE_ARCHIVE}" | head -1 | cut -d/ -f1)"
  cp -a "/tmp/${RELEASE_DIR}/." /home/container/
  rm -rf "/tmp/${RELEASE_DIR}" "${RELEASE_ARCHIVE}"

  SOURCE_CHANGED=1
  echo "Release downloaded and extracted"
else
  if [ ! -d "/home/container/.git" ]; then
    echo "Repository Missing"
    echo "Cloning repository..."
    if [ -z "$BRANCH" ]; then
      echo "Using default branch"
      git clone ${AUTH_GIT_ADDRESS} /home/container
    else
      echo "Using branch: ${BRANCH}"
      git clone -b ${BRANCH} ${AUTH_GIT_ADDRESS} /home/container
    fi
    SOURCE_CHANGED=1
    echo "Cloned repository"
  else
    echo "Updating repository..."
    PREVIOUS_COMMIT=$(git rev-parse HEAD 2>/dev/null || true)

    if [ -z "$BRANCH" ]; then
      git pull
    else
      echo "Checking out branch: ${BRANCH}"
      git fetch
      git checkout ${BRANCH}
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
fi

# Replace Startup Variables
MODIFIED_STARTUP=$(echo -e ${STARTUP} | sed -e 's/{{/${/g' -e 's/}}/}/g')
echo ":/home/container$ ${MODIFIED_STARTUP}"

# Run the Server
eval ${MODIFIED_STARTUP}