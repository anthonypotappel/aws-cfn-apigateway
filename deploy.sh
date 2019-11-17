#!/bin/bash
set -x -e -o pipefail
# ------------------------------------------------------------------- #
# Copyright (c) 2019 LINKIT, The Netherlands. All Rights Reserved.
# Author(s): Anthony Potappel
# 
# This software may be modified and distributed under the terms of
# the MIT license. See the LICENSE file for details.
# --------------------------------------------------------------------#

# --------------------------------------------------------------------#
# SCRIPT DEPENDENCIES: 
DEPENDENCIES="aws jq sed awk date"
# --------------------------------------------------------------------#

# --------------------------------------------------------------------#
# CUSTOM VARIABLES -- auto generated if commented out
# --------------------------------------------------------------------#
STACKNAME=Example-ApiGateway
#AWS_DEFAULT_REGION=eu-west-1
#AWS_PROFILE=default


# --------------------------------------------------------------------#

# Generate variables that are not set
if [ -z "${AWS_PROFILE}" ];then
    [ ! -z ${AWS_DEFAULT_PROFILE} ] \
        && AWS_PROFILE=${AWS_DEFAULT_PROFILE} \
        || AWS_PROFILE=default
fi
[ -z "${AWS_DEFAULT_REGION}" ] && AWS_DEFAULT_REGION=eu-west-1

# Default to directory name as input
[ -z "${STACKNAME}" ] && STACKNAME=$(basename "$PWD")



function error(){
    [ ! -z "$1" ] && echo "ERROR:$1"
    exit 1
}

function get_bucket(){
    # Return Name of S3 bucket deployed by RootStack
    _ROOTSTACK="$1"
    _RESPONSE=$( \
        aws cloudformation describe-stacks \
        --profile ${AWS_PROFILE} \
        --stack-name "${_ROOTSTACK}" \
        --query 'Stacks[0].Outputs[?OutputKey==`S3BucketName`].OutputValue' \
        --output text 2>/dev/null
    )
    [ ! -z "${_RESPONSE}" ] && echo "${_RESPONSE}"
    return $?
}

function get_bucket_url(){
    # Return URL of S3 bucket deployed by RootStack
    # Bucket URL is used to reference the location of (nested) stacks
    _ROOTSTACK="$1"
    _RESPONSE=$( \
        aws cloudformation describe-stacks \
        --profile ${AWS_PROFILE} \
        --stack-name "${_ROOTSTACK}" \
        --query 'Stacks[0].Outputs[?OutputKey==`S3BucketSecureURL`].OutputValue' \
        --output text 2>/dev/null
    )
    [ ! -z "${_RESPONSE}" ] && echo "${_RESPONSE}"
    return $?
}

function get_role_arn(){
    # Return ARN of Role deployed by RootStack
    _ROOTSTACK="$1"
    _RESPONSE=$( \
        aws iam list-roles --profile ${AWS_PROFILE} \
        |jq '.Roles
             | .[]
             | select(.RoleName=="'${_ROOTSTACK}'-ServiceRoleForCloudFormation")
             | .Arn' -r \
    )
    [ ! -z "${_RESPONSE}" ] && echo "${_RESPONSE}"
    return $?
}

function deploy_rootstack(){
    # Deploy RootStack -- typically contains S3 Bucket and IAM Role
    _ROOTSTACK="$1"
    aws cloudformation deploy \
        --profile ${AWS_PROFILE} \
        --no-fail-on-empty-changeset \
        --template-file cloudformation/rootstack.yaml \
        --capabilities CAPABILITY_NAMED_IAM \
        --stack-name "${_ROOTSTACK}" \
        --parameter-overrides \
            StackName="${_ROOTSTACK}"
    return $?
}

function reparse_stackname(){
    # (re-)format to acceptables chars [a-zA-Z-], remove leading/ trailing dash
    # uppercase first char
    STACKNAME=$(echo ${STACKNAME} \
        |sed 's/[^a-zA-Z0-9-]/-/g;s/-\+/-/g;s/^-\|-$//g' \
        |awk '{for (i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2)} 1'
    )

    if [ "${#STACKNAME}" -lt 1 ];then
        # default for null
        STACKNAME="None"
    elif [ "${#STACKNAME}" -gt 64 ];then
        # shorten and remove possible new leading/ trailing dashes
        STACKNAME=$(echo ${STACKNAME:0:64} |sed s'/^-\|-$//g')
    fi
    [ ! -z "${STACKNAME}" ] && echo ${STACKNAME}
    return $?
}

function main(){
    trap error ERR

    STACKNAME=$(reparse_stackname)
    ROOTSTACK="${STACKNAME}-Rootstack"
    MAINSTACK="${STACKNAME}-Main"

    # Output account used in this deployment
    aws sts get-caller-identity --profile ${AWS_PROFILE}
    deploy_rootstack "${ROOTSTACK}" 


    # Retrieve key items created by the RootStack
    BUCKET=$(get_bucket "${ROOTSTACK}")
    BUCKET_URL=$(get_bucket_url "${ROOTSTACK}")
    ROLE_ARN=$(get_role_arn "${ROOTSTACK}")

    # Copy or update files in S3 bucket created by the RootStack
    aws s3 sync \
        --profile ${AWS_PROFILE} \
        "cloudformation" \
        s3://"${BUCKET}/cloudformation"

    # Deploy MainStack
    aws cloudformation deploy \
        --profile ${AWS_PROFILE} \
        --template-file "cloudformation/main.yaml" \
        --role-arn "${ROLE_ARN}" \
        --stack-name "${MAINSTACK}" \
        --capabilities CAPABILITY_IAM CAPABILITY_AUTO_EXPAND \
        --parameter-overrides \
            S3BucketName="${BUCKET}" \
            S3BucketSecureURL="${BUCKET_URL}/cloudformation" \
            IAMServiceRole="${ROLE_ARN}" \
            LastChange=`date +%Y%m%d%H%M%S`

    # Get stackoutputs of MainStack -- allow jq to fail if none are found
    outputs=$(\
        aws cloudformation describe-stacks \
            --profile ${AWS_PROFILE} \
            --stack-name "${MAINSTACK}" \
        |(jq '.Stacks[0].Outputs[] | {"\(.OutputKey)": .OutputValue}' 2>/dev/null \
          || echo "{}") \
        |jq -s add
    )

    # disable verbosity to get clean output
    set +x
    echo "Finished succesfully! Outputs of MainStack:"
    echo $outputs| jq
}

# Verify prerequisite tools
for tool in ${DEPENDENCIES};do
    command -v ${tool} || error "${tool} not installed"
done

# Run main script
main
