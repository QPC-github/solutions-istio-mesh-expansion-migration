#!/usr/bin/env sh

# Copyright 2021 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -o nounset
set -o errexit

# shellcheck disable=SC1091
. scripts/common.sh

# Doesn't follow symlinks, but it's likely expected for most users
SCRIPT_BASENAME="$(basename "${0}")"

GKE_CLUSTER_NAME_DESCRIPTION="GKE cluster name to deploy workloads to"
GKE_CLUSTER_REGION_DESCRIPTION="ID of the region of the GKE cluster"
GOOGLE_CLOUD_PROJECT_DESCRIPTION="ID of the Google Cloud Project where the cluster to deploy to resides"

usage() {
  echo "${SCRIPT_BASENAME} - This script installs Istio in the target GKE cluster."
  echo
  echo "USAGE"
  echo "  ${SCRIPT_BASENAME} [options]"
  echo
  echo "OPTIONS"
  echo "  -h $(is_linux && echo "| --help"): ${HELP_DESCRIPTION}"
  echo "  -n $(is_linux && echo "| --cluster-name"): ${GKE_CLUSTER_NAME_DESCRIPTION}"
  echo "  -p $(is_linux && echo "| --google-cloud-project"): ${GOOGLE_CLOUD_PROJECT_DESCRIPTION}"
  echo "  -r $(is_linux && echo "| --cluster-region"): ${GKE_CLUSTER_REGION_DESCRIPTION}"
  echo
  echo "EXIT STATUS"
  echo
  echo "  ${EXIT_OK} on correct execution."
  echo "  ${ERR_VARIABLE_NOT_DEFINED} when a parameter or a variable is not defined, or empty."
  echo "  ${ERR_MISSING_DEPENDENCY} when a required dependency is missing."
  echo "  ${ERR_ARGUMENT_EVAL_ERROR} when there was an error while evaluating the program options."
}

LONG_OPTIONS="cluster-name:,cluster-region:,google-cloud-project:,help"
SHORT_OPTIONS="ce:hn:p:r:s"

echo "Checking if the necessary dependencies are available..."
check_exec_dependency "envsubst"
check_exec_dependency "gcloud"
check_exec_dependency "getopt"
check_exec_dependency "kubectl"
check_exec_dependency "sleep"

# BSD getopt (bundled in MacOS) doesn't support long options, and has different parameters than GNU getopt
if is_linux; then
  TEMP="$(getopt -o "${SHORT_OPTIONS}" --long "${LONG_OPTIONS}" -n "${SCRIPT_BASENAME}" -- "$@")"
elif is_macos; then
  TEMP="$(getopt "${SHORT_OPTIONS} --" "$@")"
fi
RET_CODE=$?
if [ ! ${RET_CODE} ]; then
  echo "Error while evaluating command options. Terminating..."
  # Ignoring SC2086 because those are defined in common.sh, and don't need quotes
  # shellcheck disable=SC2086
  exit ${ERR_ARGUMENT_EVAL_ERROR}
fi
eval set -- "${TEMP}"

GOOGLE_CLOUD_PROJECT=
GKE_CLUSTER_NAME=
GKE_CLUSTER_REGION=

while true; do
  case "${1}" in
  -n | --cluster-name)
    GKE_CLUSTER_NAME="${2}"
    shift 2
    ;;
  -r | --cluster-region)
    GKE_CLUSTER_REGION="${2}"
    shift 2
    ;;
  -p | --google-cloud-project)
    GOOGLE_CLOUD_PROJECT="${2}"
    shift 2
    ;;
  --)
    shift
    break
    ;;
  -h | --help | *)
    usage
    # Ignoring because those are defined in common.sh, and don't need quotes
    # shellcheck disable=SC2086
    exit $EXIT_OK
    break
    ;;
  esac
done

echo "Checking if the necessary parameters are set..."
check_argument "${GKE_CLUSTER_NAME}" "${GKE_CLUSTER_NAME_DESCRIPTION}"
check_argument "${GKE_CLUSTER_REGION}" "${GKE_CLUSTER_REGION_DESCRIPTION}"
check_argument "${GOOGLE_CLOUD_PROJECT}" "${GOOGLE_CLOUD_PROJECT_DESCRIPTION}"

echo "Setting the default Google Cloud project to ${GOOGLE_CLOUD_PROJECT}..."
gcloud config set project "${GOOGLE_CLOUD_PROJECT}"

ISTIO_ARCHIVE_NAME=istio-"${ISTIO_VERSION}"-linux-amd64.tar.gz

if [ ! -e "${ISTIO_PATH}" ]; then
  echo "Downloading Istio ${ISTIO_VERSION} to ${ISTIO_PATH}"
  wget --content-disposition https://github.com/istio/istio/releases/download/"${ISTIO_VERSION}"/"${ISTIO_ARCHIVE_NAME}"
  tar -xvzf "${ISTIO_ARCHIVE_NAME}"
  rm "${ISTIO_ARCHIVE_NAME}"
fi

echo "Initializing the GKE cluster credentials for ${GKE_CLUSTER_NAME}..."
gcloud container clusters get-credentials "${GKE_CLUSTER_NAME}" \
  --region="${GKE_CLUSTER_REGION}"

echo "Installing Istio..."
"${ISTIO_BIN_PATH}"/istioctl install \
  --filename "${TUTORIAL_KUBERNETES_DESCRIPTORS_PATH}"/mesh-expansion/istio-operator.yaml \
  --set profile=demo \
  --skip-confirmation
echo

wait_for_load_balancer_ip "istio-eastwestgateway" "istio-system"
wait_for_load_balancer_ip "istio-ingressgateway" "istio-system"

echo "Configuring the ingress gateway..."
kubectl apply -f "${TUTORIAL_KUBERNETES_DESCRIPTORS_PATH}"/gateway.yaml

echo "Configuring the Prometheus add-on..."
kubectl apply -f "${ISTIO_SAMPLES_PATH}"/addons/prometheus.yaml

echo "Configuring the Grafana add-on..."
GRAFANA_DESCRIPTORS_PATH="${TUTORIAL_KUBERNETES_DESCRIPTORS_PATH}"/grafana
cp "${ISTIO_SAMPLES_PATH}"/addons/grafana.yaml "${GRAFANA_DESCRIPTORS_PATH}"/
kubectl apply -k "${GRAFANA_DESCRIPTORS_PATH}"

echo "Configuring the Kiali add-on..."
KIALI_DESCRIPTOR_PATH="${ISTIO_SAMPLES_PATH}"/addons/kiali.yaml
if ! kubectl apply -f "${KIALI_DESCRIPTOR_PATH}"; then
  echo "There were errors installing Kiali. Retrying..."
  sleep 5
  kubectl apply -f "${KIALI_DESCRIPTOR_PATH}"
fi
kubectl apply -f "${TUTORIAL_KUBERNETES_DESCRIPTORS_PATH}"/kiali/virtual-service.yaml
