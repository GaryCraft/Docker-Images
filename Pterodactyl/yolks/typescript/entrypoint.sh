#!/bin/bash
cd /home/container

# Make internal Docker IP address available to processes.
export INTERNAL_IP=$(ip route get 1 | awk '{print $NF;exit}')

# If .nvm directory does not exist, copy it from /usr/local/nvm
if [ ! -d "/home/container/.nvm" ]; then
	cp -r /usr/local/nvm /home/container/.nvm
fi

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

if [ -z "${USERNAME}" ] && [ -z "${ACCESS_TOKEN}" ]; then
    echo -e "using anon api call"
else
    GIT_ADDRESS="https://${USERNAME}:${ACCESS_TOKEN}@$(echo -e ${GIT_ADDRESS} | cut -d/ -f3-)"
fi

## If using github, login to github cli
if [[ ${GIT_ADDRESS} == *"github.com"* ]]; then
	echo "Logging into GitHub CLI"
	gh auth login --with-token < <(echo -e ${ACCESS_TOKEN})
fi


if [ ! -d "/home/container/.git" ]; then
  echo "Repository Missing"
  echo "Cloning repository..."
  git clone ${GIT_ADDRESS} /home/container
  echo "Cloned repository"
else
  echo "Updating repository..."
  git pull && rm -rf ./dist
fi

# If Git submodules are present, initialize them
if [ -f /home/container/.gitmodules ]; then
  echo "Initializing submodules"
  git submodule init
  git submodule update
  echo "Initialized submodules"
fi

# Check for NODE_VERSION environment variable, if not set, default to 16
if [ -z "$NODE_VERSION" ]; then
	NODE_VERSION=18
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
  echo "Installing node_modules"
  npm install
  echo "Installed node_modules"
fi

if [ ! -d /home/container/dist ]; then
  echo "Building application"
  npm run build
  echo "Built application"
fi

# Replace Startup Variables
MODIFIED_STARTUP=$(echo -e ${STARTUP} | sed -e 's/{{/${/g' -e 's/}}/}/g')
echo ":/home/container$ ${MODIFIED_STARTUP}"

# Run the Server
eval ${MODIFIED_STARTUP}