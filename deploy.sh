#!/bin/bash
set -e

# Configuration
PROJECT_ID="vicdemo"
PLUGIN_NAME="md5-auth-plugin"
REGION="global"
# Assuming the image will be built and pushed to this location. 
# User needs to ensure Artifact Registry exists.
REPO_NAME="service-extensions" # Change this if needed
IMAGE_TAG="v1"
# Format: LOCATION-docker.pkg.dev/PROJECT_ID/REPO_NAME/IMAGE_NAME:TAG
# Using us-central1 for AR is common, or matching region. Let's assume us-central1 for build artifact.
IMAGE_URI="us-central1-docker.pkg.dev/$PROJECT_ID/$REPO_NAME/$PLUGIN_NAME:$IMAGE_TAG"
LB_NAME="http-lb-nginx"
SECRET_KEY="my-secret-key"

echo "Using Project: $PROJECT_ID"

# 1. Build the Wasm module
echo "Building Wasm module..."
# Ensure target exists
rustup target add wasm32-wasip1 || true
cd md5_plugin
cargo build --release --target wasm32-wasip1
cd ..

# 2. Build and Push Docker image (requires Docker and configured gcloud auth)
echo "Configuring Docker authentication..."
gcloud auth configure-docker us-central1-docker.pkg.dev --quiet

echo "Building Docker image..."
# Create a temporary Dockerfile
cat <<EOF > Dockerfile
FROM scratch
COPY md5_plugin/target/wasm32-wasip1/release/md5_auth_plugin.wasm plugin.wasm
EOF

echo "Pushing Docker image to $IMAGE_URI..."
docker build -t $IMAGE_URI .
# Uncomment to push if running in a real environment with docker auth
docker push $IMAGE_URI

# 3. Create/Update the Plugin
echo "Creating/Updating Service Extension Plugin..."

# Check if plugin exists (simplified logic)
if gcloud service-extensions wasm-plugins describe $PLUGIN_NAME --project=$PROJECT_ID --location=$REGION > /dev/null 2>&1; then
    echo "Plugin exists, updating..."
    # Usually we create a new version
    gcloud service-extensions wasm-plugin-versions create ${PLUGIN_NAME}-v$(date +%s) \
        --project=$PROJECT_ID \
        --location=$REGION \
        --wasm-plugin=$PLUGIN_NAME \
        --image=$IMAGE_URI \
        --plugin-config-file=config.txt
else
    echo "Creating new plugin..."
    echo "$SECRET_KEY" > config.txt
    gcloud service-extensions wasm-plugins create $PLUGIN_NAME \
        --project=$PROJECT_ID \
        --location=$REGION \
        --description="MD5 Auth Plugin" \
        --image=$IMAGE_URI \
        --main-version=${PLUGIN_NAME}-v1 \
        --plugin-config-file=config.txt
fi

# 4. Configure Edge Extension (YAML import)
echo "Configuring Edge Extension..."
cat <<EOF > edge-extension.yaml
name: md5-edge-extension
forwardingRules:
- projects/$PROJECT_ID/global/forwardingRules/md5-lb-forwarding-rule
loadBalancingScheme: EXTERNAL_MANAGED
extensionChains:
- name: "md5-chain"
  matchCondition:
    celExpression: 'request.path.startsWith("/")'
  extensions:
  - name: 'md5-auth'
    service: projects/$PROJECT_ID/locations/$REGION/wasmPlugins/$PLUGIN_NAME
    failOpen: false
    supportedEvents:
    - REQUEST_HEADERS
EOF

echo "Importing Edge Extension..."
# Note: Ensure the forwarding rule URI matches exactly what's in your project.
# The user might need to adjust the forwarding rule name in the script or YAML.
gcloud beta service-extensions lb-edge-extensions import md5-edge-extension \
    --project=$PROJECT_ID \
    --location=$REGION \
    --source=edge-extension.yaml

echo "Done."
