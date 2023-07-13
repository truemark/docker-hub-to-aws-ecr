# docker-hub-to-aws-ecr

This utility copies images & tags from Docker Hub to AWS ECR.

## Usage

./skopeo-copy.sh --api-endpoint "https://hub.docker.com/v2/repositories/" \
	--aws-account-id "XXXXXXXXXXXX" --aws-profile "XXXXXXXXXXXX_DevOpsEngineer" \
	--aws-region "us-west-2" --docker-namespace "truemark" --docker-username "username" \
	--docker-password "password" --skopeo-opts "--multi-arch all"

# Requirements

In order to use this utility you'll need to provide login credentials to Docker
Hub and configure credentials in an AWS profile with access to ECR.

## Process

This utility generates a list of images within a Docker namespace (ie;
truemark). Using this list it then queries for each of the images tags and
`tag_last_pushed` date, sorting by most recent and returning twenty tags. These
images and recent tags are then copied from Docker Hub to AWS ECR using skopeo
copy.

## Net Yet Implemented

1. The IAM access configuration for these repositories is not yet configured. This
support needs to be added to the code, but I ran out of time to implement.

2. The script currently uses local install of skopeo. Erik requested this use
the latest Docker image; not yet implemented.
