#!/bin/bash
set -e

# Define colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Function to show spinner animation
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

# Function to display a task with spinner
run_with_spinner() {
  local message=$1
  local command=$2
  
  echo -e "${YELLOW}⚙️ $message${NC}"
  eval $command &
  spinner $!
  wait $!
  
  if [ $? -eq 0 ]; then
    echo -e "${GREEN}✅ Done!${NC}"
  else
    echo -e "${RED}❌ Failed!${NC}"
    exit 1
  fi
}

# Variables
RESOURCE_GROUP="container-app-rg"
LOCATION="eastus"
ACR_NAME="demoacrregistry" # Will be appended with unique string
IMAGE_NAME="flask-app"
IMAGE_TAG="latest"
CONTAINER_APP_NAME="demo-flask-app"
CONTAINER_APP_ENV_NAME="myenv"

# Print header
echo -e "${BLUE}======================================${NC}"
echo -e "${BLUE}    Azure Container App Deployment    ${NC}"
echo -e "${BLUE}======================================${NC}"
echo ""

# Create resource group
echo -e "${YELLOW}🔷 Creating resource group...${NC}"
run_with_spinner "Creating resource group $RESOURCE_GROUP in $LOCATION" "az group create --name $RESOURCE_GROUP --location $LOCATION > /dev/null"

# Deploy ACR using Bicep
echo -e "\n${YELLOW}🔷 Deploying Azure Container Registry...${NC}"
echo -e "${BLUE}  This may take a few minutes${NC}"
ACR_OUTPUT=$(az deployment group create \
  --resource-group $RESOURCE_GROUP \
  --template-file apps/acr.bicep \
  --parameters acrName=$ACR_NAME \
  --query properties.outputs)

# Extract ACR details
FULL_ACR_NAME=$(echo $ACR_OUTPUT | jq -r '.acrName.value')
ACR_LOGIN_SERVER=$(echo $ACR_OUTPUT | jq -r '.acrLoginServer.value')

echo -e "${GREEN}✅ ACR deployed successfully!${NC}"
echo -e "${BLUE}  ACR Name:        ${NC}$FULL_ACR_NAME"
echo -e "${BLUE}  ACR Login Server:${NC} $ACR_LOGIN_SERVER"

# Login to ACR
echo -e "\n${YELLOW}🔷 Logging in to ACR...${NC}"
run_with_spinner "Authenticating with $FULL_ACR_NAME" "az acr login --name $FULL_ACR_NAME > /dev/null"

# Build and push Docker image
echo -e "\n${YELLOW}🔷 Building and pushing Docker image...${NC}"
echo -e "${BLUE}  Step 1/3:${NC} Building image as $IMAGE_NAME:$IMAGE_TAG"
docker build -t $IMAGE_NAME:$IMAGE_TAG . > /dev/null 2>&1 &
spinner $!
wait $!

echo -e "${BLUE}  Step 2/3:${NC} Tagging image as $ACR_LOGIN_SERVER/$IMAGE_NAME:$IMAGE_TAG"
docker tag $IMAGE_NAME:$IMAGE_TAG $ACR_LOGIN_SERVER/$IMAGE_NAME:$IMAGE_TAG > /dev/null 2>&1 &
spinner $!
wait $!

echo -e "${BLUE}  Step 3/3:${NC} Pushing to registry"
docker push $ACR_LOGIN_SERVER/$IMAGE_NAME:$IMAGE_TAG > /dev/null 2>&1 &
spinner $!
wait $!

echo -e "${GREEN}✅ Image pushed successfully!${NC}"

# Deploy Container App using Bicep
echo -e "\n${YELLOW}🔷 Deploying Azure Container App...${NC}"
echo -e "${BLUE}  This may take a few minutes${NC}"
CONTAINER_APP_OUTPUT=$(az deployment group create \
  --resource-group $RESOURCE_GROUP \
  --template-file apps/containerapp.bicep \
  --parameters \
      containerAppName=$CONTAINER_APP_NAME \
      containerAppEnvironmentName=$CONTAINER_APP_ENV_NAME \
      acrName=$FULL_ACR_NAME \
      imageName=$IMAGE_NAME \
      imageTag=$IMAGE_TAG \
  --query properties.outputs)

# Extract Container App FQDN
APP_FQDN=$(echo $CONTAINER_APP_OUTPUT | jq -r '.containerAppFqdn.value')

# Print completion message
echo -e "\n${GREEN}✅ Deployment complete!${NC}"
echo -e "${BLUE}======================================${NC}"
echo -e "${BLUE}    Container App URL:${NC}"
echo -e "${GREEN}    https://$APP_FQDN${NC}"
echo -e "${BLUE}======================================${NC}"
echo ""
echo -e "${YELLOW}To clean up resources:${NC}"
echo -e "az group delete --name $RESOURCE_GROUP --yes"