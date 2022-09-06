#!/bin/bash
SUFFIX=$RANDOM

export RESOURCE_GROUP="honeycomb-collector$SUFFIX"
export ENVIRONMENT_NAME="collector-env$SUFFIX"
export LOCATION=uksouth
export STORAGE_ACCOUNT_NAME="collectorappstorage$SUFFIX"
export STORAGE_SHARE_NAME="collector-config"
export STORAGE_MOUNT_NAME="configmount"
export CONTAINER_APP_NAME="collector"
export COLLECTOR_IMAGE=otel/opentelemetry-collector
export HONEYCOMB_API_KEY=$1

echo "Creating a Otel Collector in an Azure Container App"
echo "Honeycomb API Key is ${HONEYCOMB_API_KEY:0:5}****"

# Create Resource Group
echo "Creating Resource Group called $RESOURCE_GROUP in $LOCATION"
az group create --name $RESOURCE_GROUP --location $LOCATION --output none

# Create Storage Account
echo "Creating a Storage account called $STORAGE_ACCOUNT_NAME"
az storage account create \
  --resource-group $RESOURCE_GROUP \
  --name $STORAGE_ACCOUNT_NAME \
  --location "$LOCATION" \
  --kind StorageV2 \
  --sku Standard_LRS \
  --enable-large-file-share \
  --output none

# Create Azure File Share
echo "Creating a File Share called $STORAGE_SHARE_NAME"
az storage share-rm create \
  --resource-group $RESOURCE_GROUP \
  --storage-account $STORAGE_ACCOUNT_NAME \
  --name $STORAGE_SHARE_NAME \
  --quota 1024 \
  --enabled-protocols SMB \
  --output none

STORAGE_ACCOUNT_KEY=`az storage account keys list -n $STORAGE_ACCOUNT_NAME --query "[0].value" -o tsv`

echo "Uploading the config file to the file share"
az storage file upload -s $STORAGE_SHARE_NAME \
  --source config.yaml \
  --account-key $STORAGE_ACCOUNT_KEY \
  --account-name $STORAGE_ACCOUNT_NAME > /dev/null

# Create Container App Environment
echo "Creating a container App environment called $ENVIRONMENT_NAME"
az containerapp env create \
  --name $ENVIRONMENT_NAME \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION \
  --output none 2>/dev/null

# Map the Azure File share to the Environment
echo "Setting the Azure File storage on the Container App Environment"
az containerapp env storage set \
  --access-mode ReadWrite \
  --azure-file-account-name $STORAGE_ACCOUNT_NAME \
  --azure-file-account-key $STORAGE_ACCOUNT_KEY \
  --azure-file-share-name $STORAGE_SHARE_NAME \
  --storage-name $STORAGE_MOUNT_NAME \
  --name $ENVIRONMENT_NAME \
  --resource-group $RESOURCE_GROUP \
  --output none 2>/dev/null

# Create the container app
echo "Creating the container app called $CONTAINER_APP_NAME"
az containerapp create \
  --name $CONTAINER_APP_NAME \
  --resource-group $RESOURCE_GROUP \
  --environment $ENVIRONMENT_NAME \
  --image $COLLECTOR_IMAGE \
  --min-replicas 1 \
  --max-replicas 1 \
  --target-port 4318 \
  --ingress external \
  --secrets "honeycomb-api-key=$HONEYCOMB_API_KEY" \
  --env-vars "HONEYCOMB_API_KEY=secretref:honeycomb-api-key" "HONEYCOMB_LOGS_DATASET=azure-logs" \
  --output none 2>/dev/null

# Download Config for the app
echo "Downloading the container app config"
az containerapp show \
  --name $CONTAINER_APP_NAME \
  --resource-group $RESOURCE_GROUP \
  --output yaml > app.yaml 2>/dev/null

# Add the Storage mount and remove secrets
yq -i '
  .properties.template.volumes[0].name = "config" |
  .properties.template.volumes[0].storageName = strenv(STORAGE_MOUNT_NAME) |
  .properties.template.volumes[0].storageType = "AzureFile" |
  .properties.template.containers[0].volumeMounts[0].volumeName = "config" |
  .properties.template.containers[0].volumeMounts[0].mountPath = "/etc/otelcol" |
  del(.properties.configuration.secrets)
' app.yaml

# Upload the config
echo "Uploading new Config"
az containerapp update \
  --name $CONTAINER_APP_NAME \
  --resource-group $RESOURCE_GROUP \
  --yaml app.yaml \
  --output none 2>/dev/null

export CONTAINER_APP_INGRESS=$(yq '.properties.configuration.ingress.fqdn' app.yaml)

export OTEL_EXPORTER_OTLP_ENDPOINT=https://$CONTAINER_APP_INGRESS/v1/traces
echo ""
echo "======"
echo "Collector is at $CONTAINER_APP_INGRESS"
echo "Traces url is https://$CONTAINER_APP_INGRESS/v1/traces"
echo "Otel-cli has been setup, to test copy this:"
echo ""
echo "export OTEL_EXPORTER_OTLP_ENDPOINT=https://$CONTAINER_APP_INGRESS/v1/traces"
echo "otel-cli span --service \"CLI\" \ "
echo "   --name \"OpenTelemetry Collector In Azure Container Apps\" \ "
echo "   --start \$(date +%s.%N) \ "
echo "   --end \$(date +%s.%N) \ "
echo "   --verbose"
echo ""
echo "HAPPY TRACING!!!!"

rm app.yaml

echo "Done"