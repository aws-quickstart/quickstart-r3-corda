#!/bin/bash

set -euo pipefail

# Parameters

IP_ADDRESS="${1:-}"
COUNTRY_CODE="$(echo "${2:-GB}" | sed 's/[^A-Za-z]//g')"
LOCATION="$(echo "${3:-London}" | sed 's/[^A-Za-z -]//g')"
DB_URL="${4:-}"
DB_SCHEMA="public"
DB_USER="${5:-CordaUser}"     # Constrained by template
DB_PWD="${6:-}"               # Constrained by template
ONE_TIME_DOWNLOAD_KEY="$(echo "${7:-}" | sed 's/[^A-Za-z0-9-]//g')"
RPC_IP="$(echo "${8:-}" | sed 's#/.*$##')"
P2P_LOAD_BALANCER="${9:-}"
RPC_LOAD_BALANCER="${10:-}"
REGION="${11:-}"
TESTNET_URL="${12:-https://onboarder.prod.ws.r3.com}"

# Constants

INSTALL_DIR="/opt/corda"
NODE_CONFIG_FILE="/opt/corda/node.conf"

PLATFORM="AWS"
DISTRO="ENTERPRISE"

DRIVER_FILE="postgresql-42.2.2.jar"
DRIVER_URL="https://jdbc.postgresql.org/download/$DRIVER_FILE"

# Helper functions

log() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') [INFO] $@"
}

download() {
    sudo curl -s -L "$1" -o "$INSTALL_DIR/$2"
}

error() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') [ERROR] $@" >> /dev/stderr
    exit 1
}

# Fail fast if one-time-key has not been set

log "Installing on IP=${IP_ADDRESS} in location='${LOCATION}, ${COUNTRY_CODE}' ..."
log "Using database '${DB_URL}' with schema '${DB_SCHEMA}' and user '${DB_USER}' ..."

if [ -z "$ONE_TIME_DOWNLOAD_KEY" ]; then
    error "One time download key not provided"
fi

log "Using one time download key '${ONE_TIME_DOWNLOAD_KEY}' ..."

# Set up Corda installation directory

log "Installing Corda into '$INSTALL_DIR' ..."

sudo adduser --system --no-create-home --group corda
sudo mkdir -p "$INSTALL_DIR"
sudo mkdir -p "$INSTALL_DIR/certificates"
cd "$INSTALL_DIR"

# Download and install database driver JAR

log "Downloading JDBC database driver ..."

download "$DRIVER_URL" "drivers/$DRIVER_FILE"

log "Installed JDBC database driver '$DRIVER_FILE'"

# Retrieve configuration, identity, truststore and binaries

log "Waiting for distribution bundle '$INSTALL_DIR/corda.zip' to become available ..."

while true; do
    if [ -f "/opt/corda/sharedfs/bundle-available" ]; then
        break
    else
        echo "Waiting ..."
        sleep 10
    fi
done

log "Copying distribution bundle from file share to '$INSTALL_DIR/corda.zip' ..."

cp "/opt/corda/sharedfs/corda.zip" "/opt/corda/"

log "Unpacking distribution ..."

sudo unzip /opt/corda/corda.zip 2> /dev/null || error "Unable to unzip generated node bundle; was the correct one time download key used?"

log "Setting permissions for node directories ..."

sudo chown -R corda:corda "$INSTALL_DIR"

log "Patching configuration file ..."

ESC_DB_URL="$(echo "$DB_URL" | sed 's#/#\\/#g')"
sudo sed -i "/p2pAddress/s/__IPADDRESS__/$IP_ADDRESS/g" "$NODE_CONFIG_FILE" || error "Failed to set P2P IP address in config"
sudo sed -i "/address/s/__IPADDRESS__/$RPC_IP/g" "$NODE_CONFIG_FILE" || error "Failed to set RPC IP address in config"
sudo sed -i "/adminAddress/s/__IPADDRESS__/$RPC_IP/g" "$NODE_CONFIG_FILE" || error "Failed to set RPC admin IP address in config"
sudo sed -i "s/__DATASOURCE_URL__/jdbc:postgresql:\/\/$ESC_DB_URL/g" "$NODE_CONFIG_FILE" || error "Failed to set database URL in config"
sudo sed -i "s/__DATASOURCE_USER__/$DB_USER/g" "$NODE_CONFIG_FILE" || error "Failed to set database username in config"
sudo sed -i "s/__DATASOURCE_PASSWORD__/$DB_PWD/g" "$NODE_CONFIG_FILE" || error "Failed to set database password in config"
sudo sed -i "s/__DATABASE_SCHEMA_NAME__/$DB_SCHEMA/g" "$NODE_CONFIG_FILE" || error "Failed to set database schema name in config"
sudo sed -i "s/^[ ]*\"extraAdvertisedServiceIds\".*$//" "$NODE_CONFIG_FILE" || error "Failed to remove 'extraAdvertisedServiceIds' config"
sudo sed -i "s/^[ ]*\"webAddress\".*$//" "$NODE_CONFIG_FILE" || error "Failed to remove 'webAddress' config"

log "Node configuration completed"

INSTANCE_ID="$(wget -q -O - http://169.254.169.254/latest/meta-data/instance-id)"
log "Add instance $INSTANCE_ID to load balancer $P2P_LOAD_BALANCER ..."
aws elb register-instances-with-load-balancer --load-balancer-name "$P2P_LOAD_BALANCER" --instances "$INSTANCE_ID" --region "$REGION"
log "Add instance $INSTANCE_ID to load balancer $RPC_LOAD_BALANCER ..."
aws elb register-instances-with-load-balancer --load-balancer-name "$RPC_LOAD_BALANCER" --instances "$INSTANCE_ID" --region "$REGION"
log "Instance added to load balancers"

log "Installation successfully completed"
