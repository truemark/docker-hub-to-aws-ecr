#!/usr/bin/env bash

set -euo pipefail

# Set default values for the variables
API_ENDPOINT=""
AWS_ACCOUNT_ID=""
AWS_PROFILE=""
AWS_REGION=""
DOCKER_NAMESPACE=""
DOCKER_USERNAME=""
DOCKER_PASSWORD=""
SKOPEO_OPTS=""

# Parse command-line options
while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        --api-endpoint)
        API_ENDPOINT="$2"
        shift
        shift
        ;;
        --aws-account-id)
        AWS_ACCOUNT_ID="$2"
        shift
        shift
        ;;
        --aws-profile)
        AWS_PROFILE="$2"
        shift
        shift
        ;;
        --aws-region)
        AWS_REGION="$2"
        shift
        shift
        ;;
        --docker-namespace)
        DOCKER_NAMESPACE="$2"
        shift
        shift
        ;;
        --docker-username)
        DOCKER_USERNAME="$2"
        shift
        shift
        ;;
        --docker-password)
        DOCKER_PASSWORD="$2"
        shift
        shift
        ;;
        --skopeo-opts)
        SKOPEO_OPTS="$2"
        shift
        shift
        ;;
        *)
        echo "Unknown option: $1"
        exit 1
        ;;
    esac
done

# Verify that all required options are provided
if [[ -z $API_ENDPOINT || -z $AWS_ACCOUNT_ID || -z $AWS_PROFILE || -z $AWS_REGION || \
	-z $DOCKER_NAMESPACE || -z $DOCKER_USERNAME || -z $DOCKER_PASSWORD || -z $SKOPEO_OPTS ]]; then
    echo "Missing required options. Usage: $0 --api-endpoint <endpoint> --aws-account-id <account_id> --aws-profile <profile> --aws-region <region> \
		--docker-namespace <namespace> --docker-username <username> --docker-password <password> --skopeo-opts <options>"
    exit 1
fi

# Retrieve auth token using username/password
TOKEN=$(curl -sf -H "Content-Type: application/json" -X POST -d '{"username": "'${DOCKER_USERNAME}'", "password": "'${DOCKER_PASSWORD}'"}' https://hub.docker.com/v2/users/login/ | jq -r .token)

# Get a count of the images. determine page count at 25 per page. add 1 for remainder.
image_count=$(curl -sf -H "Authorization: JWT ${TOKEN}" "${API_ENDPOINT}${DOCKER_NAMESPACE}" | jq -r '.count')
page_count=$(( ($image_count / 25) + 1 ))
echo $image_count
echo $page_count

# Query each page. filter for image name. append to repo_names list
for (( _page=1; _page<=page_count; _page++ )); do
    repo_names+=$(curl -sf -H "Authorization: JWT ${TOKEN}" "${API_ENDPOINT}${DOCKER_NAMESPACE}?page_size=25&page=${_page}" | jq -r '.results|.[]|.name')
    repo_names+=" " ## required padding between loops otherwise result names runtogether
done

# Check if the request was successful or exit
if [ ! "$repo_names" ]; then
    echo "Failed to retrieve repositories from Docker Hub."
    exit 1
fi

# Skopeo logins
skopeo login --username ${DOCKER_USERNAME} --password ${DOCKER_PASSWORD} docker.io
aws ecr get-login-password --region ${AWS_REGION} | skopeo login --username AWS --password-stdin ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com

repo_list=$(aws ecr describe-repositories | jq -r '.repositories[].repositoryName')

# TODO: troubleshooting
#for _repo in $repo_names; do
#    for _ecr_repo in ${repo_list[@]}; do
#        if [ ! $_repo = $_ecr_repo ]; then
#            echo "Creating $_repo"
#            #echo "aws ecr create-repository --repository-name "${_repo}" --region "${AWS_REGION}" --profile "${AWS_PROFILE}" --no-cli-pager"
#        else
#            echo "Repository already exists"
#        fi
#    done
#done

##TODO:
#    tag_list=$(skopeo --override-os linux inspect docker://docker.io/"${DOCKER_NAMESPACE}/${_repo}" | jq -r '.RepoTags[]')
#    for _tag in $tag_list; do
#        echo "Copying ${_repo}:${_tag}..."
#        skopeo copy docker://docker.io/${DOCKER_NAMESPACE}/${_repo}:${_tag} docker://${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${_repo}:${_tag} ${SKOPEO_OPTS}
#        echo
#    done
