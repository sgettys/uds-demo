#!/bin/bash
set -euo pipefail
# Step 1: Find the current network CIDR

# Use `ip` command to find the interface and the associated network CIDR.
# Replace `eth0` with the correct network interface (use `ip addr` to list all interfaces).


# Step 3: Pass the IPs into the Zarf package deploy command
VERSION=$(uds zarf version)
ARCH=$(uname -m)
if [[ "$ARCH" == "aarch64" ]]; then
  ARCH="arm64"
elif [[ "$ARCH" == "x86_64" ]]; then
  ARCH="amd64"
else
  echo "Unsupported architecture: $ARCH"
  exit 1
fi
mkdir -p packages
ZARF_INIT_PATH="$HOME/.zarf-cache/zarf-init-${ARCH}-${VERSION}.tar.zst"
if [ ! -f "$ZARF_INIT_PATH" ]; then
  #echo "Zarf init package not found. Connect to the internet and run 'uds zarf tools download-init -o ~/.zarf-cache' to download the package."
  uds zarf tools download-init
fi
if uds zarf package inspect init > /dev/null 2>&1; then
  echo "Zarf is already initialized."
else
  echo "Zarf is not initialized. Running zarf init..."
  uds zarf init --set K3S_ARGS="--disable traefik --disable servicelb" --components=k3s --confirm
  # Apply the UDS overrides to core-dns necessary for the istio rewrites to work
  kubectl apply -n kube-system -f core-dns-custom.yaml
  kubectl rollout restart deployment coredns -n kube-system
  mkdir -p /etc/kubernetes
  cp /root/.kube/config /etc/kubernetes/uds-kubeconfig
  chmod 644 /etc/kubernetes/uds-kubeconfig
fi
if uds zarf package inspect metallb > /dev/null 2>&1; then
  echo "Metallb already installed"
  ADMIN_INGRESS_IP=$(kubectl -n metallb-system get ipaddresspools admin-ingressgateway -o jsonpath='{.spec.addresses[0]}' | awk -F/ '{print $1}')
  TENANT_INGRESS_IP=$(kubectl -n metallb-system get ipaddresspools tenant-ingressgateway -o jsonpath='{.spec.addresses[0]}' | awk -F/ '{print $1}')
  PASSTHROUGH_INGRESS_IP=$(kubectl -n metallb-system get ipaddresspools passthrough-ingressgateway -o jsonpath='{.spec.addresses[0]}' | awk -F/ '{print $1}')
else
  NETWORK=$(ip -o -f inet addr show | awk '/inet 192.168.10/ {print $4}' | head -n 1)
  
  # If no network is found, exit the script with an error
  if [[ -z "$NETWORK" ]]; then
    echo "Could not determine network CIDR. Exiting."
    exit 1
  fi
  
  echo "Found network CIDR: $NETWORK"
  
  # Step 2: Get a pool of 3 IPs using the free_ips.sh script
  mapfile -t GATEWAY_IPS < <(./free_ips.sh "$NETWORK" 3)
  
  # Check if 3 IPs were returned
  if [[ ${#GATEWAY_IPS[@]} -ne 3 ]]; then
    echo "Could not find 3 valid IPs. Exiting."
    exit 1
  fi
  
  # Assign each IP to the appropriate variable
  ADMIN_INGRESS_IP="${GATEWAY_IPS[0]}"
  TENANT_INGRESS_IP="${GATEWAY_IPS[1]}"
  PASSTHROUGH_INGRESS_IP="${GATEWAY_IPS[2]}"
  echo "Installing metallb package"
  METALLB_PACKAGE_VERSION="0.1.2"
  METALLB_PACKAGE="zarf-package-metallb-${ARCH}-${METALLB_PACKAGE_VERSION}.tar.zst"
  if [ ! -f "${METALLB_PACKAGE}" ]; then 
    uds zarf package pull oci://ghcr.io/defenseunicorns/packages/metallb:${METALLB_PACKAGE_VERSION}
  fi
  uds zarf package deploy ${METALLB_PACKAGE} \
    --set IP_ADDRESS_ADMIN_INGRESSGATEWAY="$ADMIN_INGRESS_IP" \
    --set IP_ADDRESS_TENANT_INGRESSGATEWAY="$TENANT_INGRESS_IP" \
    --set IP_ADDRESS_PASSTHROUGH_INGRESSGATEWAY="$PASSTHROUGH_INGRESS_IP" \
    --confirm
fi
# Get cluster internal IP
CLUSTER_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
## Public DNS servers for fallback (e.g., Google and Cloudflare)
#PUBLIC_DNS="8.8.8.8 8.8.4.4 1.1.1.1 1.0.0.1"
#echo "Configuring dnsmasq..."
#mkdir -p /etc/dnsmasq.d
#systemctl stop systemd-resolved
#systemctl disable systemd-resolved
## Create a minimal /etc/dnsmasq.conf to include custom configurations
#if [ ! -f /etc/dnsmasq.conf ]; then
#    echo "Creating minimal /etc/dnsmasq.conf..."
#    tee /etc/dnsmasq.conf > /dev/null <<EOL
## Include all configurations from /etc/dnsmasq.d/
#conf-dir=/etc/dnsmasq.d
## Disable dnsmasq's built-in DNS recursion to avoid recursive loops
#domain-needed
#bogus-priv
#no-resolv
## Enable DHCP for USB Ethernet adapter
##interface=enxa0cec8b88e06
##dhcp-range=192.168.50.10,192.168.50.100,12h
##dhcp-option=option:router,192.168.50.1
##dhcp-option=option:dns-server,192.168.50.1
#EOL
#fi
#
## Create the custom configuration file for dnsmasq
#tee /etc/dnsmasq.d/custom-uds-domains.conf > /dev/null <<EOL
#port=53
## Resolve *.admin.uds.dev to admin ingress IP
#address=/admin.uds.dev/$ADMIN_INGRESS_IP
#
## Resolve *.uds.dev to tenant ingress IP
#address=/uds.dev/$TENANT_INGRESS_IP
#
## Resolve *.uds.demo to the host IP for cluster and registry
#address=/uds.demo/$CLUSTER_IP
#EOL
#
## Append each public DNS server to the configuration, limited to non-local domains
#for dns in $PUBLIC_DNS; do
#    echo "server=$dns" | tee -a /etc/dnsmasq.d/custom-uds-domains.conf > /dev/null
#done
#
## Add settings to avoid DNS forwarding for local domains and restrict recursive queries
#tee -a /etc/dnsmasq.d/custom-uds-domains.conf > /dev/null <<EOL
## Prevent forwarding for local domains
#local=/admin.uds.dev/
#local=/uds.dev/
#local=/uds.demo/
#EOL
#
#if [ ! -f /etc/systemd/system/dnsmasq.service ]; then
#  echo "Creating dnsmasq systemd service file..."
#  tee /etc/systemd/system/dnsmasq.service > /dev/null <<EOL
#[Unit]
#Description=dnsmasq - A lightweight DNS and DHCP server
#After=network.target
#
#[Service]
#ExecStart=/usr/sbin/dnsmasq -k
#Restart=on-failure
#
#[Install]
#WantedBy=multi-user.target
#EOL
#
#  # Reload systemd to recognize the new service
#  systemctl daemon-reload
#fi
#
#echo "Restarting dnsmasq service..."
#systemctl restart dnsmasq
#systemctl enable dnsmasq
#
#if systemctl is-active --quiet dnsmasq; then
#  echo "dnsmasq is configured and running. Domain resolutions are set up."
#else
#  echo "Error: dnsmasq service failed to start. Please check configuration."
#  exit 1
#fi
#echo "Installing UDS Remote Agent"
#pushd agent
#set +e
#if uds zarf package inspect uds-remote-agent > /dev/null 2>&1; then
#  echo "UDS Remote Agent already installed, removing and reinstalling"
#  uds zarf package remove uds-remote-agent --confirm
#fi
#set -e
#uds zarf package deploy zarf-package-uds-remote-agent-amd64-0.2.1-uds.0.tar.zst --confirm
#popd
#echo "Installing Registry"
#pushd registry
#uds zarf package deploy zarf-package-distribution-distribution-amd64-0.1.0.tar.zst --components=distribution-registry-service --confirm
#popd
echo "Installing UDS Core"
if [ ! -f packages/zarf-package-core-base-amd64-0.39.0.tar.zst ]; then
  uds zarf package pull oci://ghcr.io/defenseunicorns/packages/uds/core-base:0.39.0-upstream -o packages
fi
set +e
if ! uds zarf package inspect core-base; then
  uds zarf package deploy packages/zarf-package-core-base-amd64-0.39.0.tar.zst --confirm
fi
if [ ! -f packages/zarf-package-core-identity-authorization-amd64-0.39.0.tar.zst ]; then
  uds zarf package pull oci://ghcr.io/defenseunicorns/packages/uds/core-identity-authorization:0.39.0-upstream -o packages
fi
set +e
if ! uds zarf package inspect core-identity-authorization; then
  uds zarf package deploy packages/zarf-package-core-identity-authorization-amd64-0.39.0.tar.zst --confirm
fi
set -e
echo "Cluster IP: $CLUSTER_IP"
echo "Assigned IPs:"
echo "Admin Ingress IP: $ADMIN_INGRESS_IP"
echo "Tenant Ingress IP: $TENANT_INGRESS_IP"
echo "Passthrough Ingress IP: $PASSTHROUGH_INGRESS_IP"
