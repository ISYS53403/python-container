#!/bin/bash
set -e

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Spinner function
spinner() {
  local pid=$1
  local delay=0.1
  local spinstr='|/-\'
  while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
    local temp=${spinstr#?}
    printf " [%c]  " "$spinstr"
    local spinstr=$temp${spinstr%"$temp"}
    sleep $delay
    printf "\b\b\b\b\b\b"
  done
  printf "    \b\b\b\b"
}

# Function to display step messages
step_msg() {
  echo -e "\n${BLUE}${BOLD}=== $1 ===${NC}"
}

# Function to display success messages
success_msg() {
  echo -e "${GREEN}✓ $1${NC}"
}

# Function to display info messages
info_msg() {
  echo -e "${YELLOW}ℹ $1${NC}"
}

# Function to execute command with spinner
run_with_spinner() {
  echo -e "${YELLOW}$1${NC}"
  shift
  "$@" > /dev/null 2>&1 &
  spinner $!
  echo -e "${GREEN}Done!${NC}"
}

# Variables (you can override these)
RESOURCE_GROUP="flask-app-rg"
LOCATION="eastus"
SSH_KEY_PATH="$HOME/.ssh/id_rsa.pub"
DOCKERFILE_PATH="./Dockerfile"
IMAGE_NAME="flask-app"
IMAGE_TAG="latest"
DNS_ZONE_NAME="flask-app-demo.com" # Change this to your domain name
APP_HOSTNAME="flask-app" # Change this to your desired subdomain

# Display banner
echo -e "${BLUE}${BOLD}"
echo "╔════════════════════════════════════════════════════════╗"
echo "║            AZURE KUBERNETES SERVICE DEPLOYER           ║"
echo "╚════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# Create resource group if it doesn't exist
step_msg "Creating resource group"
info_msg "Resource Group: $RESOURCE_GROUP | Location: $LOCATION"
run_with_spinner "Creating resource group..." az group create --name $RESOURCE_GROUP --location $LOCATION
success_msg "Resource group created or already exists"

# Check if SSH key exists
step_msg "Checking SSH key"
if [ ! -f "$SSH_KEY_PATH" ]; then
  info_msg "SSH key not found at $SSH_KEY_PATH. Generating new SSH key..."
  ssh-keygen -t rsa -b 4096 -f "${SSH_KEY_PATH%.*}" -N "" > /dev/null 2>&1
  success_msg "SSH key generated"
else
  success_msg "SSH key found at $SSH_KEY_PATH"
fi

SSH_KEY=$(cat "$SSH_KEY_PATH")

# Deploy Bicep template
step_msg "Deploying AKS and ACR resources with HTTP application routing"
info_msg "This might take a while..."
echo -ne "${YELLOW}Deploying resources... ${NC}"
DEPLOYMENT_OUTPUT=$(az deployment group create \
  --resource-group $RESOURCE_GROUP \
  --template-file k8s/aks.bicep \
  --parameters sshRSAPublicKey="$SSH_KEY" \
  --parameters dnsZoneName="$DNS_ZONE_NAME" \
  --parameters appHostname="$APP_HOSTNAME" \
  --parameters httpApplicationRoutingEnabled=true \
  --query "properties.outputs" \
  --output json)
success_msg "AKS and ACR resources deployed successfully"

ACR_LOGIN_SERVER=$(echo $DEPLOYMENT_OUTPUT | jq -r '.acrLoginServer.value')
AKS_FQDN=$(echo $DEPLOYMENT_OUTPUT | jq -r '.controlPlaneFQDN.value')
APP_DNS_NAME=$(echo $DEPLOYMENT_OUTPUT | jq -r '.applicationDnsName.value // "Not configured"')
HTTP_ROUTING_ZONE=$(echo $DEPLOYMENT_OUTPUT | jq -r '.httpApplicationRoutingZone.value // "Not configured"')
CLUSTER_NAME=$(az aks list -g $RESOURCE_GROUP --query "[0].name" -o tsv)

info_msg "AKS cluster: $CLUSTER_NAME"
info_msg "ACR login server: $ACR_LOGIN_SERVER"
info_msg "Application DNS: $APP_DNS_NAME"
info_msg "HTTP Routing Zone: $HTTP_ROUTING_ZONE"

# Get ACR credentials
ACR_NAME=${ACR_LOGIN_SERVER%%'.azurecr.io'}
step_msg "Getting ACR credentials"
info_msg "ACR Name: $ACR_NAME"
run_with_spinner "Retrieving ACR credentials..." az acr credential show -n $ACR_NAME > /dev/null
ACR_USERNAME=$(az acr credential show -n $ACR_NAME --query "username" -o tsv)
ACR_PASSWORD=$(az acr credential show -n $ACR_NAME --query "passwords[0].value" -o tsv)
success_msg "ACR credentials retrieved"

# Login to ACR
step_msg "Logging in to ACR"
run_with_spinner "Logging in to ACR..." az acr login --name $ACR_NAME
success_msg "Logged in to ACR"

# Build and push Docker image to ACR
step_msg "Building and pushing Docker image"
info_msg "Image: ${ACR_LOGIN_SERVER}/${IMAGE_NAME}:${IMAGE_TAG}"
echo -ne "${YELLOW}Building image... ${NC}"
docker build -t "${ACR_LOGIN_SERVER}/${IMAGE_NAME}:${IMAGE_TAG}" -f $DOCKERFILE_PATH . > /dev/null
success_msg "Image built"

echo -ne "${YELLOW}Pushing image to ACR... ${NC}"
docker push "${ACR_LOGIN_SERVER}/${IMAGE_NAME}:${IMAGE_TAG}" > /dev/null
success_msg "Image pushed to ACR"

# Get credentials for AKS
step_msg "Getting credentials for AKS cluster"
run_with_spinner "Retrieving AKS credentials..." az aks get-credentials --resource-group $RESOURCE_GROUP --name $CLUSTER_NAME --overwrite-existing
success_msg "AKS credentials retrieved"

# Determine Ingress controller and host
if [ "$HTTP_ROUTING_ZONE" != "Not configured" ] && [ ! -z "$HTTP_ROUTING_ZONE" ]; then
  # Use HTTP application routing if available
  INGRESS_HOST="${APP_HOSTNAME}.${HTTP_ROUTING_ZONE}"
  INGRESS_CLASS="addon-http-application-routing"
  success_msg "Using HTTP Application Routing addon for ingress"
else
  # Install NGINX ingress controller
  step_msg "Installing NGINX Ingress Controller"
  run_with_spinner "Adding Helm repo..." helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
  run_with_spinner "Updating Helm repos..." helm repo update
  run_with_spinner "Installing NGINX Ingress..." helm install nginx-ingress ingress-nginx/ingress-nginx
  success_msg "NGINX Ingress Controller installed"
  
  # Get the NGINX controller's public IP
  echo -ne "${YELLOW}Waiting for NGINX Ingress Controller IP... ${NC}"
  RETRIES=0
  MAX_RETRIES=30
  while [ $RETRIES -lt $MAX_RETRIES ]; do
    INGRESS_CONTROLLER_IP=$(kubectl get service nginx-ingress-ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    if [ ! -z "$INGRESS_CONTROLLER_IP" ]; then
      break
    fi
    sleep 10
    printf "."
    RETRIES=$((RETRIES+1))
  done
  echo ""
  
  if [ -z "$INGRESS_CONTROLLER_IP" ]; then
    echo -e "${RED}${BOLD}Ingress Controller IP not acquired within timeout period${NC}"
    INGRESS_CONTROLLER_IP="pending"
  else
    success_msg "NGINX Ingress Controller IP: $INGRESS_CONTROLLER_IP"
  fi
  
  # Setup DNS for custom domain if specified
  if [ "$DNS_ZONE_NAME" != "example.com" ]; then
    step_msg "Setting up ExternalDNS for custom domain"
    run_with_spinner "Installing ExternalDNS..." kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/external-dns/master/docs/tutorials/azure/service-account.yaml
    
    # Create a ConfigMap for Azure credentials
    cat > externaldns-config.yaml << EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: externaldns-config
data:
  azure.json: |
    {
      "tenantId": "$(az account show --query tenantId -o tsv)",
      "subscriptionId": "$(az account show --query id -o tsv)",
      "resourceGroup": "$RESOURCE_GROUP",
      "aadClientId": "$(az account show --query user.name -o tsv)",
      "aadClientSecret": "managed"
    }
EOF

    kubectl apply -f externaldns-config.yaml
    
    # Deploy ExternalDNS
    cat > externaldns.yaml << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: external-dns
spec:
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: external-dns
  template:
    metadata:
      labels:
        app: external-dns
    spec:
      containers:
      - name: external-dns
        image: registry.k8s.io/external-dns/external-dns:v0.13.1
        args:
        - --source=service
        - --source=ingress
        - --domain-filter=$DNS_ZONE_NAME
        - --provider=azure
        - --azure-resource-group=$RESOURCE_GROUP
        volumeMounts:
        - name: azure-config-file
          mountPath: /etc/kubernetes
          readOnly: true
      volumes:
      - name: azure-config-file
        configMap:
          name: externaldns-config
EOF

    kubectl apply -f externaldns.yaml
    success_msg "ExternalDNS deployed"
  fi
  
  INGRESS_HOST="${APP_HOSTNAME}.${DNS_ZONE_NAME}"
  INGRESS_CLASS="nginx"
fi

info_msg "Ingress host will be: $INGRESS_HOST"

# Create Kubernetes deployment YAML
step_msg "Creating Kubernetes deployment and Ingress YAML"
info_msg "Creating flask-app-deployment.yaml"

cat > flask-app-deployment.yaml << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: flask-app
spec:
  replicas: 3
  selector:
    matchLabels:
      app: flask-app
  template:
    metadata:
      labels:
        app: flask-app
    spec:
      containers:
      - name: flask-app
        image: ${ACR_LOGIN_SERVER}/${IMAGE_NAME}:${IMAGE_TAG}
        ports:
        - containerPort: 5000
        resources:
          limits:
            cpu: "0.5"
            memory: "512Mi"
          requests:
            cpu: "0.2"
            memory: "256Mi"
---
apiVersion: v1
kind: Service
metadata:
  name: flask-app
  annotations:
    external-dns.alpha.kubernetes.io/hostname: ${INGRESS_HOST}
spec:
  type: ClusterIP
  ports:
  - port: 80
    targetPort: 5000
  selector:
    app: flask-app
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: flask-app-ingress
  annotations:
    kubernetes.io/ingress.class: ${INGRESS_CLASS}
spec:
  rules:
  - host: ${INGRESS_HOST}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: flask-app
            port:
              number: 80
EOF
success_msg "Kubernetes deployment and Ingress YAML created"

# Deploy to Kubernetes
step_msg "Deploying to Kubernetes"
run_with_spinner "Applying Kubernetes manifests..." kubectl apply -f flask-app-deployment.yaml
success_msg "Kubernetes deployment applied"

# Wait for Ingress to be ready
step_msg "Waiting for Ingress to be configured"
info_msg "This might take a few minutes..."
RETRIES=0
MAX_RETRIES=30
echo -ne "${YELLOW}"
while [ $RETRIES -lt $MAX_RETRIES ]; do
  printf "."
  INGRESS_STATUS=$(kubectl get ingress flask-app-ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
  if [ ! -z "$INGRESS_STATUS" ]; then
    break
  fi
  sleep 10
  RETRIES=$((RETRIES+1))
done
echo -e "${NC}"

if [ -z "$INGRESS_STATUS" ]; then
  echo -e "${RED}${BOLD}Ingress not fully configured within timeout period${NC}"
  echo -e "${YELLOW}You can check the ingress status with: kubectl get ingress flask-app-ingress${NC}"
  INGRESS_IP="pending"
else
  INGRESS_IP=$(kubectl get ingress flask-app-ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
  success_msg "Ingress configured with IP: $INGRESS_IP"
fi

echo -e "\n${GREEN}${BOLD}╔════════════════════════════════════════════════════════╗"
echo "║               DEPLOYMENT COMPLETED SUCCESSFULLY           ║"
echo "╚════════════════════════════════════════════════════════╝"
echo -e "\n${GREEN}${BOLD}Your Flask app is now running at:${NC} ${BOLD}http://$INGRESS_HOST${NC}\n"
echo -e "${YELLOW}Note: DNS propagation may take some time. You can add an entry to your hosts file for immediate testing:${NC}"
echo -e "${YELLOW}$INGRESS_IP $INGRESS_HOST${NC}\n"

# Print summary
echo -e "${BLUE}${BOLD}=== Deployment Summary ===${NC}"
echo -e "${YELLOW}Resource Group:${NC} $RESOURCE_GROUP"
echo -e "${YELLOW}AKS Cluster:${NC} $CLUSTER_NAME"
echo -e "${YELLOW}ACR Registry:${NC} $ACR_NAME"
echo -e "${YELLOW}App URL:${NC} http://$INGRESS_HOST"
echo -e "${YELLOW}App IP:${NC} $INGRESS_IP"
echo -e "${YELLOW}Kubectl command:${NC} kubectl get pods"
echo -e "${YELLOW}Cleanup command:${NC} az group delete --name $RESOURCE_GROUP --yes --no-wait"