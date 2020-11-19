#!/usr/bin/env bash

set -e
set -x

THISDIR=$(dirname "$0")

source $1

RELEASE_PREFIX=$(echo "${RELEASE_PREFIX}" | tr '[:upper:]' '[:lower:]')
PRODUCT_RELEASE_NAME=$RELEASE_PREFIX-$PRODUCT_NAME
POSTGRES_RELEASE_NAME=$PRODUCT_RELEASE_NAME-pgsql
FUNCTEST_RELEASE_NAME=$PRODUCT_RELEASE_NAME-functest

HELM_PACKAGE_DIR=target/helm

currentContext=$(kubectl config current-context)

echo Current context: $currentContext

clusterType=$(case "${currentContext}" in
  *eks*) echo EKS;;
  *aks*) echo AKS;;
  *gke*) echo GKE;;
  *shared-dev*|*default-context*) echo KITT;;
  *) echo CUSTOM;;
esac)


# Install the bitnami postgresql Helm chart
helm repo add bitnami https://charts.bitnami.com/bitnami --force-update

mkdir -p "$LOG_DOWNLOAD_DIR"

# Use the product name for the name of the postgres database, username and password.
# These must match the credentials stored in the Secret pre-loaded into the namespace,
# which the application will use to connect to the database.
helm install -n "${TARGET_NAMESPACE}" --wait \
   "$POSTGRES_RELEASE_NAME" \
   --values "$THISDIR/postgres-values.yaml" \
   --set fullnameOverride="$POSTGRES_RELEASE_NAME" \
   --set image.tag="$POSTGRES_APP_VERSION" \
   --set postgresqlDatabase="$PRODUCT_NAME" \
   --set postgresqlUsername="$PRODUCT_NAME" \
   --set postgresqlPassword="$PRODUCT_NAME" \
   --version "$POSTGRES_CHART_VERSION" \
   bitnami/postgresql > $LOG_DOWNLOAD_DIR/helm_install_log.txt

for file in ${PRODUCT_CHART_VALUES_FILES}.yaml ${PRODUCT_CHART_VALUES_FILES}-${clusterType}.yaml ; do
  [ -f "$file" ] && valueOverrides+="--values $file "
done

[ -n "$DOCKER_IMAGE_REGISTRY" ] && valueOverrides+="--set image.registry=$DOCKER_IMAGE_REGISTRY "
[ -n "$DOCKER_IMAGE_VERSION" ] && valueOverrides+="--set image.tag=$DOCKER_IMAGE_VERSION "
valueOverrides+="--set image.pullPolicy=Always "

# Ask Helm to generate the YAML that it will send to Kubernetes in the "install" step later, so
# that we can look at it for diagnostics.
helm template \
   "$PRODUCT_RELEASE_NAME" \
   "$CHART_SRC_PATH" \
   --debug \
   ${valueOverrides} \
    > $LOG_DOWNLOAD_DIR/$PRODUCT_RELEASE_NAME.yaml

# Package the product's Helm chart
helm package "$CHART_SRC_PATH" \
   --destination "$HELM_PACKAGE_DIR"

# Install the product's Helm chart
helm install -n "${TARGET_NAMESPACE}" --wait \
   "$PRODUCT_RELEASE_NAME" \
   ${valueOverrides} \
   "$HELM_PACKAGE_DIR/${PRODUCT_NAME}"-*.tgz >> $LOG_DOWNLOAD_DIR/helm_install_log.txt

if [ $? -ne 0 ]
then
  kubectl get events -n "${TARGET_NAMESPACE}" --sort-by=.metadata.creationTimestamp
  exit 1;
fi

# Run the chart's tests
helm test "$PRODUCT_RELEASE_NAME" --logs -n "${TARGET_NAMESPACE}"

# Package and install he functest helm chart
helm package "$THISDIR/../charts/functest" --destination "$HELM_PACKAGE_DIR"

INGRESS_DOMAIN_VARIABLE_NAME="INGRESS_DOMAIN_$clusterType"
INGRESS_DOMAIN=${!INGRESS_DOMAIN_VARIABLE_NAME}

helm install --wait \
   "$FUNCTEST_RELEASE_NAME" \
   --set clusterType="${clusterType}",ingressDomain="$INGRESS_DOMAIN",productReleaseName="$PRODUCT_RELEASE_NAME",product="$PRODUCT_NAME" \
   "$HELM_PACKAGE_DIR/functest-0.1.0.tgz"

# wait until the Ingress we just created starts serving up non-error responses - there may be a lag
INGRESS_URI="https://${PRODUCT_RELEASE_NAME}.${INGRESS_DOMAIN}/"
echo "Waiting for $INGRESS_URI to be ready"
while :
do
   STATUS_CODE=$(curl -s -o /dev/null -w %{http_code} "$INGRESS_URI")
   echo "Received status code $STATUS_CODE from $INGRESS_URI"
   if [ "$STATUS_CODE" -lt 400 ]; then
     echo "Ingress is ready"
     break
   fi
done
