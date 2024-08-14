#!/bin/bash

# variaveis

export RESOURCE_GROUP="myResourceGroup"
export LOCATION="eastus"
export CLUSTER_NAME="myAKSCluster"
export SERVICE_ACCOUNT_NAMESPACE="default"
export SERVICE_ACCOUNT_NAME="workload-identity-sa"
export SUBSCRIPTION="$(az account show --query id --output tsv)"
export USER_ASSIGNED_IDENTITY_NAME="myIdentity"
export FEDERATED_IDENTITY_CREDENTIAL_NAME="myFedIdentity"
export STORAGE_RESOURCE_GROUP="myResourceGroup"
export STORAGE_ACCOUNT_NAME="mystorageaccountlab2024"
export LOCATION="eastus"
export CONTAINER_NAME="mycontainer"
export FILE_PATH="./files/secrets.txt"
export BLOB_NAME="secrets.txt"


# cria resource group
saz group create --name "${RESOURCE_GROUP}" --location "${LOCATION}"

# cria cluster
az aks create --resource-group "${RESOURCE_GROUP}" --name "${CLUSTER_NAME}" --enable-oidc-issuer --enable-workload-identity --generate-ssh-keys

# exporta issuer
export AKS_OIDC_ISSUER="$(az aks show --name "${CLUSTER_NAME}" --resource-group "${RESOURCE_GROUP}" --query "oidcIssuerProfile.issuerUrl" --output tsv)"

# cria service account
az identity create --name "${USER_ASSIGNED_IDENTITY_NAME}" --resource-group "${RESOURCE_GROUP}" --location "${LOCATION}" --subscription "${SUBSCRIPTION}"

# exporta client id
export USER_ASSIGNED_CLIENT_ID="$(az identity show --resource-group "${RESOURCE_GROUP}" --name "${USER_ASSIGNED_IDENTITY_NAME}" --query 'clientId' --output tsv)"

# associa service account ao cluster
az aks get-credentials --name "${CLUSTER_NAME}" --resource-group "${RESOURCE_GROUP}"

# cria service account
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  annotations:
    azure.workload.identity/client-id: "${USER_ASSIGNED_CLIENT_ID}"
  name: "${SERVICE_ACCOUNT_NAME}"
  namespace: "${SERVICE_ACCOUNT_NAMESPACE}"
EOF

# cria credencial federada
az identity federated-credential create --name ${FEDERATED_IDENTITY_CREDENTIAL_NAME} --identity-name "${USER_ASSIGNED_IDENTITY_NAME}" --resource-group "${RESOURCE_GROUP}" --issuer "${AKS_OIDC_ISSUER}" --subject system:serviceaccount:"${SERVICE_ACCOUNT_NAMESPACE}":"${SERVICE_ACCOUNT_NAME}" --audience api://AzureADTokenExchange

# cria storage account
az storage account create \
    --name "${STORAGE_ACCOUNT_NAME}" \
    --resource-group "${STORAGE_RESOURCE_GROUP}" \
    --location "${LOCATION}" \
    --sku Standard_LRS \
    --kind StorageV2

# cria container
az storage container create \
    --name "${CONTAINER_NAME}" \
    --account-name "${STORAGE_ACCOUNT_NAME}"

# upload de arquivo
az storage blob upload \
    --account-name "${STORAGE_ACCOUNT_NAME}" \
    --container-name "${CONTAINER_NAME}" \
    --name "${BLOB_NAME}" \
    --file "${FILE_PATH}"

# exporta storage account id
export STORAGE_ACCOUNT_ID=$(az storage account show \
    --name "${STORAGE_ACCOUNT_NAME}" \
    --resource-group "${STORAGE_RESOURCE_GROUP}" \
    --query id \
    --output tsv)

# exporta principal id
export IDENTITY_PRINCIPAL_ID=$(az identity show \
    --name "${USER_ASSIGNED_IDENTITY_NAME}" \
    --resource-group "${STORAGE_RESOURCE_GROUP}" \
    --query principalId \
    --output tsv)

# atribui role
az role assignment create \
    --assignee-object-id "${IDENTITY_PRINCIPAL_ID}" \
    --role "Storage Blob Data Reader" \
    --scope "${STORAGE_ACCOUNT_ID}" \
    --assignee-principal-type ServicePrincipal


# cria workload
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: sample-workload-identity-storage-account
  namespace: ${SERVICE_ACCOUNT_NAMESPACE}
  labels:
    azure.workload.identity/use: "true"
spec:
  serviceAccountName: ${SERVICE_ACCOUNT_NAME}
  containers:
    - name: azure-cli-container
      image: mcr.microsoft.com/azure-cli:latest
      command: ["/bin/sh", "-c"]
      args: [ "while true; do sleep 3600; done;" ]
      env:
      - name: STORAGE_ACCOUNT_NAME
        value: ${STORAGE_ACCOUNT_NAME}
      - name: CONTAINER_NAME
        value: ${CONTAINER_NAME}
      - name: BLOB_NAME
        value: ${BLOB_NAME}
      - name: USER_ASSIGNED_CLIENT_ID
        value: ${USER_ASSIGNED_CLIENT_ID}
  nodeSelector:
    kubernetes.io/os: linux
EOF

kubectl exec -ti sample-workload-identity-storage-account -- bash

# dentro do pod

az storage blob list \
    --account-name "${STORAGE_ACCOUNT_NAME}" \
    --container-name "${CONTAINER_NAME}" \
    --auth-mode login

az storage blob download \
    --account-name "${STORAGE_ACCOUNT_NAME}" \
    --container-name "${CONTAINER_NAME}" \
    --name "${BLOB_NAME}" \
    --file "./${BLOB_NAME}" \
    --auth-mode login

kubectl exec -ti pod sample-workload-identity-storage-account -- /bin/bash