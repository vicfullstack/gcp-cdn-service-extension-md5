#!/bin/bash
set -e

PROJECT_ID="vicdemo"
REGION="asia-east2"
ZONE="asia-east2-a"
IG_NAME="nginx-uig-hk"
EXISTING_IG_URI="projects/$PROJECT_ID/zones/$ZONE/instanceGroups/$IG_NAME"
HEALTH_CHECK_NAME="http-healthcheck" # Reusing existing
BS_NAME="nginx-uig-hk-managed"
URL_MAP_NAME="md5-lb-map"
TARGET_PROXY_NAME="md5-lb-proxy"
FR_NAME="md5-lb-forwarding-rule"

echo "Setting up Managed Load Balancer infrastructure..."

# 1. Create Backend Service (EXTERNAL_MANAGED)
if ! gcloud compute backend-services describe $BS_NAME --global --project=$PROJECT_ID > /dev/null 2>&1; then
    echo "Creating Backend Service $BS_NAME..."
    gcloud compute backend-services create $BS_NAME \
        --load-balancing-scheme=EXTERNAL_MANAGED \
        --protocol=HTTP \
        --port-name=http \
        --health-checks=$HEALTH_CHECK_NAME \
        --global \
        --project=$PROJECT_ID
else
    echo "Backend Service $BS_NAME already exists."
fi

# 2. Add Backend to Service
# Check if backend is already added
if ! gcloud compute backend-services describe $BS_NAME --global --project=$PROJECT_ID | grep -q "$IG_NAME"; then
    echo "Adding instance group to backend service..."
    gcloud compute backend-services add-backend $BS_NAME 
        --instance-group=$IG_NAME 
        --instance-group-zone=$ZONE 
        --global 
        --balancing-mode=UTILIZATION 
        --max-utilization=0.8 
        --capacity-scaler=1.0 
        --project=$PROJECT_ID
else
    echo "Backend already added."
fi

# 3. Create URL Map
if ! gcloud compute url-maps describe $URL_MAP_NAME --global --project=$PROJECT_ID > /dev/null 2>&1; then
    echo "Creating URL Map $URL_MAP_NAME..."
    gcloud compute url-maps create $URL_MAP_NAME \
        --default-service=$BS_NAME \
        --global \
        --project=$PROJECT_ID
else
    echo "URL Map $URL_MAP_NAME already exists."
fi

# 4. Create Target HTTP Proxy
if ! gcloud compute target-http-proxies describe $TARGET_PROXY_NAME --global --project=$PROJECT_ID > /dev/null 2>&1; then
    echo "Creating Target HTTP Proxy $TARGET_PROXY_NAME..."
    gcloud compute target-http-proxies create $TARGET_PROXY_NAME \
        --url-map=$URL_MAP_NAME \
        --global \
        --project=$PROJECT_ID
else
    echo "Target HTTP Proxy $TARGET_PROXY_NAME already exists."
fi

# 5. Create Forwarding Rule (EXTERNAL_MANAGED)
if ! gcloud compute forwarding-rules describe $FR_NAME --global --project=$PROJECT_ID > /dev/null 2>&1; then
    echo "Creating Forwarding Rule $FR_NAME..."
    gcloud compute forwarding-rules create $FR_NAME \
        --load-balancing-scheme=EXTERNAL_MANAGED \
        --network-tier=PREMIUM \
        --target-http-proxy=$TARGET_PROXY_NAME \
        --global \
        --ports=80 \
        --project=$PROJECT_ID
else
    echo "Forwarding Rule $FR_NAME already exists."
fi

echo "Infrastructure setup complete. Forwarding Rule: $FR_NAME"
