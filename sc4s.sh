#!/bin/bash

# Function to check if an environment variable exists, if not, prompt the user for the value and store it
set_env_var() {
    local var_name=$1
    local var_prompt=$2
    local is_sensitive=$3  # Flag to determine if input should be masked

    if [ -z "${!var_name}" ]; then
        if [ "$is_sensitive" == "true" ]; then
            read -s -p "$var_prompt" var_value
            echo
        else
            read -p "$var_prompt" var_value
        fi
        export "$var_name"="$var_value"
        
        # Make the variable persist across reboots
        if ! grep -q "^${var_name}=" /etc/environment; then
            echo "$var_name=\"$var_value\"" | sudo tee -a /etc/environment > /dev/null
        fi
    else
        echo "$var_name is already set to ${!var_name}"
    fi
}

# Function to check and create volume directories if they do not exist
check_and_create_directory() {
    local dir_path=$1
    if [ ! -d "$dir_path" ]; then
        echo "Directory $dir_path does not exist. Creating it..."
        sudo mkdir -p "$dir_path"
        sudo chown sc4s:sc4s "$dir_path"
    else
        echo "Directory $dir_path already exists."
    fi
}

# Check and set environment variables for SC4S
set_env_var "SC4S_HEC_URL" "Enter the HEC URL (e.g., https://hec-url:8088): " false
set_env_var "SC4S_HEC_TOKEN" "Enter the HEC Token: " true
set_env_var "SC4S_IMAGE" "Enter the SC4S container image (e.g., myprivateregistry.com/splunk/sc4s:latest): " false

# Set and store registry credentials
set_env_var "REGISTRY_USERNAME" "Enter the registry username: " false
set_env_var "REGISTRY_PASSWORD" "Enter the registry password: " true

# Ensure podman is installed, if not, install it
if ! command -v podman &> /dev/null
then
    echo "Podman not found, installing..."
    sudo apt-get update
    sudo apt-get install -y podman conntrack
else
    echo "Podman is already installed."
fi

# Log into the private container registry (using interactive password prompt for security)
echo "Logging into registry..."
podman login $SC4S_IMAGE --username $REGISTRY_USERNAME --password $REGISTRY_PASSWORD

# Create sysctl configuration for SC4S
cat <<EOF | sudo tee /etc/sysctl.d/sc4s.conf
net.core.rmem_default = 1703936
net.core.rmem_max = 1703936
net.ipv4.ip_forward = 1
net.ipv4.ip_unprivileged_port_start=514
EOF

# Apply the sysctl configuration
sudo sysctl -p /etc/sysctl.d/sc4s.conf

# Enable and start podman socket service
sudo systemctl enable --now podman.socket

# Create the SC4S container user and directories
sudo useradd -c "SC4S container user" -d /opt/sc4s -m sc4s
sudo install -d -g sc4s -o sc4s -m 0755 /opt/sc4s/{local,archive,tls}

# Create environment file for SC4S
cat <<EOF | sudo tee /opt/sc4s/env_file
SPLUNK_HEC_URL=$SC4S_HEC_URL
SPLUNK_HEC_TOKEN=$SC4S_HEC_TOKEN
SC4S_DEST_SPLUNK_HEC_TLS_VERIFY=no
SC4S_DEST_SPLUNK_HEC_WORKERS="1"
SC4S_DEST_SPLUNK_HEC_GLOBAL=yes

SC4S_LISTEN_DEFAULT_TCP_PORT=514
SC4S_LISTEN_DEFAULT_UDP_PORT=514

# For debug. Don't leave on
#SC4S_DEST_GLOBAL_ALTERNATES=d_hec_debug
EOF

# Create the Podman volume for SC4S persistent storage
sudo su -l sc4s -c "podman volume create splunk-sc4s-var"

# Check and create necessary directories for volume mounts
check_and_create_directory "/opt/sc4s/local"
check_and_create_directory "/opt/sc4s/archive"
check_and_create_directory "/opt/sc4s/tls"
check_and_create_directory "/var/lib/syslog-ng"

# Create a systemd service file for SC4S
cat <<EOF | sudo tee /etc/systemd/system/sc4s.service
[Unit]
Description=SC4S Container
Wants=NetworkManager.service network-online.target
After=NetworkManager.service network-online.target

[Install]
WantedBy=multi-user.target

[Service]
AmbientCapabilities=CAP_NET_BIND_SERVICE
Delegate=true
User=sc4s
Group=sc4s
PermissionsStartOnly=true
TimeoutStartSec=0

Environment="SC4S_IMAGE=$SC4S_IMAGE"
Environment="SC4S_PERSIST_MOUNT=splunk-sc4s-var:/var/lib/syslog-ng:Z"
Environment="SC4S_LOCAL_MOUNT=/opt/sc4s/local:/etc/syslog-ng/conf.d/local:Z"
Environment="SC4S_ARCHIVE_MOUNT=/opt/sc4s/archive:/var/lib/syslog-ng/archive:Z"
Environment="SC4S_TLS_MOUNT=/opt/sc4s/tls:/etc/syslog-ng/tls:z"

ExecStartPre=/usr/bin/podman login $SC4S_IMAGE --username $REGISTRY_USERNAME
ExecStartPre=/usr/bin/podman pull $SC4S_IMAGE
ExecStartPre=/usr/bin/bash -c "/usr/bin/systemctl set-environment SC4SHOST=\$(hostname -s)"

ExecStart=/usr/bin/podman run \
        -e "SC4S_CONTAINER_HOST=\${SC4SHOST}" \
        -v "\$SC4S_PERSIST_MOUNT" \
        -v "\$SC4S_LOCAL_MOUNT" \
        -v "\$SC4S_ARCHIVE_MOUNT" \
        -v "\$SC4S_TLS_MOUNT" \
        --env-file=/opt/sc4s/env_file \
        --health-cmd="/healthcheck.sh" \
        --health-interval=10s --health-retries=6 --health-timeout=6s \
        --network host \
        --name SC4S \
        --rm \$SC4S_IMAGE

Restart=on-abnormal
EOF

# Reload the systemd daemon and enable the SC4S service
sudo systemctl daemon-reload
sudo systemctl enable --now sc4s.service
