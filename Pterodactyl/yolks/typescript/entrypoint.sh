#!/bin/bash
cd /home/container

# Make internal Docker IP address available to processes.
export INTERNAL_IP=$(ip route get 1 | awk '{print $NF;exit}')

# Print Node.js Version
echo "Node.js Version: "
node -v

## add git ending if it's not on the address
if [[ ${GIT_ADDRESS} != *.git ]]; then
    GIT_ADDRESS=${GIT_ADDRESS}.git
fi

if [ -z "${USERNAME}" ] && [ -z "${ACCESS_TOKEN}" ]; then
    echo -e "using anon api call"
else
    GIT_ADDRESS="https://${USERNAME}:${ACCESS_TOKEN}@$(echo -e ${GIT_ADDRESS} | cut -d/ -f3-)"
fi

if [ ! -d "/home/container/.git" ]; then
  echo "Cloning repository..."
  git clone ${GIT_ADDRESS} /home/container
else
  echo "Updating repository..."
  git pull
fi

if [ -f /home/container/package.json ]; then
  echo "Installing node_modules"
  npm ci
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