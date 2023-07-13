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

# Skopeo logins
skopeo login --username ${DOCKER_USERNAME} --password ${DOCKER_PASSWORD} docker.io
aws ecr get-login-password --region ${AWS_REGION} | skopeo login --username AWS --password-stdin ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com

# Retrieve auth token using username/password
TOKEN=$(curl -sf -H "Content-Type: application/json" -X POST -d '{"username": "'"${DOCKER_USERNAME}"'", "password": "'"${DOCKER_PASSWORD}"'"}' https://hub.docker.com/v2/users/login/ | jq -r .token)

RESPONSE=$(curl -sf -H "Authorization: JWT ${TOKEN}" "${API_ENDPOINT}${DOCKER_NAMESPACE}")

# Get a count of the images. determine page count at 25 per page. add 1 for remainder.
image_count=$(echo "$RESPONSE" | jq -r '.count')
page_count=$(( (image_count / 25) + 1 ))

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

ecr_repo_list=$(aws ecr describe-repositories | jq -r '.repositories[].repositoryName')

for _repo in $repo_names; do
    image_tags=()
    all_tags=()
    sorted_tags=()
    recent_tags=()

    # Create repository if not found
    if ! echo "$ecr_repo_list" | grep -q "$_repo"; then
        echo "Creating $_repo in ECR..."
        echo "aws ecr create-repository --repository-name "${_repo}" --region "${AWS_REGION}" --profile "${AWS_PROFILE}" --no-cli-pager"
    else
        echo "Repository $_repo already exists."
    fi

    # Query & parse image tags
    tag_count=$(curl -sf -H "Authorization: JWT ${TOKEN}" "${API_ENDPOINT}${DOCKER_NAMESPACE}/${_repo}/tags/" | jq -r '.count')

    # If no tags, bail out of loop
    if [ "$tag_count" = 0 ]; then
        continue
    elif [ "$tag_count" -gt 250 ]; then
        tag_count=250
    fi
    page_count=$(( (tag_count / 25) + 1 ))

    # Query each page. filter for tag name. append to image_tags list
    for (( _page=1; _page<=page_count; _page++ )); do
        image_tags+=$(curl -sf -H "Authorization: JWT ${TOKEN}" "${API_ENDPOINT}${DOCKER_NAMESPACE}/${_repo}/tags/?page_size=25&page=${_page}" | jq -r '.results|.[]|.name')
        image_tags+=" "
    done

    for _tag in $image_tags; do
        tag_date=$(curl -sf -H "Authorization: JWT ${TOKEN}" "https://hub.docker.com/v2/namespaces/${DOCKER_NAMESPACE}/repositories/${_repo}/tags/${_tag}" | jq -r '.tag_last_pushed')
        all_tags+=("$_tag|${tag_date}")
    done
        
    # Sort the tags array based on tag dates in descending order
    sorted_tags=$(printf "%s\n" "${all_tags[@]}" | sort -t '|' -k2 -r | head -n 20)

    ## Extract only the tag names from the sorted tags
    for _sorted_tag in "${sorted_tags[@]}"; do
      tag_name=$(echo "$_sorted_tag" | cut -d '|' -f1)
      recent_tags+=("$tag_name")
    done
    
    ## Use skopeo copy to sync $repo:$tag to ECR
    for _recent in $recent_tags; do
        echo "Copying ${_repo}:${_recent}..."
        skopeo copy docker://docker.io/${DOCKER_NAMESPACE}/${_repo}:${_recent} docker://${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${_repo}:${_recent} ${SKOPEO_OPTS}
    done
done
