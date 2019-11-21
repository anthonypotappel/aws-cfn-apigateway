#!/bin/bash
# ------------------------------------------------------------------- #
# Copyright (c) 2019 LINKIT, The Netherlands. All Rights Reserved.
# Author(s): Anthony Potappel
# 
# This software may be modified and distributed under the terms of
# the MIT license. See the LICENSE file for details.
# --------------------------------------------------------------------#
set -x -e -o pipefail

# base script dependencies -- if GITURL is used, git is also required
DEPENDENCIES="aws jq sed awk date basename"

function usage(){
    PROGNAME="cfn_deploy.sh"
    cat << USAGE
  Notes
    ${PROGNAME} deploy a CloudFormation stack on AWS.
  Usage:
    command:    ${PROGNAME} <ACTION> [ENVIRONMENT_FILE]

  ACTIONS
    --deploy        Deploy or Update stack
    --delete        Delete stack
    --status        Retrieve status of stack
    --account       Verify account used to deploy or delete
    --delete_configuration
                    Delete configuration stack 
                    -- ensure no stack depends on it!

  ENVIRONMENT_FILE
    Optional file. All variables are retrieved from environment and
    can be overridden by an ENVIRONMENT_FILE. Defaults are generated
    for missing variables, where possible.

    # Name of stack should be unique per AWS account. Defaults to
    # name of directory where ${PROGNAME} is run from.
    STACKNAME=cfn-deploy-demo

    # (optional) source contents from a GIT repository
    GITURL=https://github.com/[GROUP]/REPO].git?branch=master&commit=

    # name of template_file to be run in mainstack
    # default path lookup: current scriptpath; ./\${TEMPLATE_FILE}
    # if GITURL is defined: ./build/current/\${TEMPLATE_FILE}
    TEMPLATE_FILE=cloudformation/main.yaml

    # AWS_* PARAMETERS are all loaded as-is
    # check: https://docs.aws.amazon.com/\
                cli/latest/userguide/cli-chap-configure.html

    # use profiles, configuration in ~/.aws/[config,credentials]
    AWS_PROFILE=DevAccount  --or-- AWS_DEFAULT_PROFILE=DevAccount

    # set region -- defaults to eu-west-1
    AWS_DEFAULT_REGION=eu-west-1

    # credentials through environment
    # values are discarded if AWS_PROFILE is defined
    AWS_ACCESS_KEY_ID=secretaccount
    AWS_SECRET_ACCESS_KEY=mysecret
    AWS_SESSION_TOKEN=sts-generated-token

USAGE
    return 0
}


function error(){
    # Default error function with hard exit
    [ ! -z "$1" ] && echo "ERROR:$1"
    exit 1
}

function git_destination(){
    # Return clean repository name -- filter out .git and any parameters
    _var=$(basename "${1}" |sed 's/\.git$//g;s/[^a-zA-Z0-9_-]//g')
    [ ! -z "${_var}" ] && echo "${_var}"
    return $?
}

function git_parameter(){
    # Return parameter from GIT URL -- return _default if not found
    filter="${1}"
    default="${2}"
    url="${3}"
    var=$( \
        basename "${url}" \
        |sed 's/?\|$/__/g;
              s/.*__\([-a-zA-Z0-9=]*\)__/\1/g;
              s/.*__$//g;
              s/^.*\('${filter}'=[A-Za-z0-9-]*\).*$/\1/g;
              s/^'${filter}'=//g' \
    )
    [ -z "${var}" ] && var="${default}"
    echo "${var}"
    return 0
}

function update_from_git(){
    # Fetch repository and checkout to specified branch tag/commit
    [ -z "${1}" ] && return 1

    # for this function, git is a requirement
    command -v git || error "git not installed"

    url="${1}"
    branch=$(git_parameter "branch" "master" "${url}")
    commit=$(git_parameter "commit" "" "${url}")

    repository_url=$(echo "${url}" |sed 's/?.*//g')
    repository_name=$(git_destination "${repository_url}") || return 1
    destination="./build/${repository_name}"

    [ ! -d "./build" ] && (mkdir -p "./build" || return 1)

    echo "Retrieving ${repository_url}"

    [ -e "${destination}/.git" ] \
        && (cd "${destination}" && git fetch) \
        || git clone -b "${branch}" "${repository_url}" "${destination}" \
        || return 1

    # point to given branch commit/tag (or latest if latter is empty)
    (cd "${destination}" && git checkout -B ${branch} ${commit} || return 1)

    # succesful install - update symlink
    [ -e "./build/current" ] && (rm -f "./build/current" || return 1)
    ln -sf "${repository_name}" "./build/current"
    return $?
}

function get_bucket(){
    # Return Name of S3 bucket deployed by RootStack
    stackname="$1"
    response=$( \
        aws cloudformation describe-stacks ${PROFILE_STR} \
        --stack-name "${stackname}" \
        --query 'Stacks[0].Outputs[?OutputKey==`S3BucketName`].OutputValue' \
        --output text 2>/dev/null
    )
    [ ! -z "${response}" ] && echo "${response}"
    return $?
}

function get_bucket_url(){
    # Return URL of S3 bucket deployed by RootStack
    # Bucket URL is used to reference the location of (nested) stacks
    stackname="$1"
    response=$( \
        aws cloudformation describe-stacks ${PROFILE_STR} \
        --stack-name "${stackname}" \
        --query 'Stacks[0].Outputs[?OutputKey==`S3BucketSecureURL`].OutputValue' \
        --output text 2>/dev/null
    )
    [ ! -z "${response}" ] && echo "${response}"
    return $?
}

function get_role_arn(){
    # Return ARN of Role deployed by RootStack
    stackname="$1"
    response=$( \
        aws iam list-roles ${PROFILE_STR} \
        |jq '.Roles
             | .[]
             | select(.RoleName=="'${stackname}'-ServiceRoleForCloudFormation")
             | .Arn' -r \
    )
    [ ! -z "${response}" ] && echo "${response}"
    return $?
}

function deploy_configuration(){
    # Deploy Configuration-- typically contains S3 Bucket and IAM Role
    stackname="$1"
    aws cloudformation deploy ${PROFILE_STR} \
        --no-fail-on-empty-changeset \
        --template-file cloudformation/configuration.yaml \
        --capabilities CAPABILITY_NAMED_IAM \
        --stack-name "${stackname}" \
        --parameter-overrides StackName="${stackname}"
    return $?
}

function process_stackname(){
    # (Re-)Format to CloudFormation compatible stack names
    # [a-zA-Z-], remove leading/ trailing dash, uppercase first char (just cosmetics)
    STACKNAME=$(echo ${1} \
        |sed 's/[^a-zA-Z0-9-]/-/g;s/-\+/-/g;s/^-\|-$//g' \
        |awk '{for (i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2)} 1'
    )

    if [ "${#STACKNAME}" -lt 1 ];then
        # this should never happen, but if name is empty default to Unknown
        STACKNAME="Unknown"
    elif [ "${#STACKNAME}" -gt 64 ];then
        # shorten name, and remove possible new leading/ trailing dashes
        STACKNAME=$(echo ${STACKNAME:0:64} |sed s'/^-\|-$//g')
    fi
    [ ! -z "${STACKNAME}" ] && echo ${STACKNAME}
    return $?
}

function account(){
    # --account Verify account used to deploy or delete
    # exit on error
    trap error ERR

    # disable verbosity to get clean output
    set +x
    outputs=$(aws sts get-caller-identity ${PROFILE_STR})
    echo "Account used:"
    echo "${outputs}" | jq
    exitcode=$?

    # re-enable verbosity
    set -x
    return ${exitcode}
}

function delete(){
    # --delete  Delete stack
    # exit on error
    trap error ERR

    # output account used in this deployment
    account

    configuration_stack="${STACKNAME}-Configuration"
    main_stack="${STACKNAME}-Main"

    # Retrieve key items created by the configuration stack
    role_arn=$(get_role_arn "${configuration_stack}")

    # delete main_stack
    aws cloudformation delete-stack ${PROFILE_STR} \
        --role-arn "${role_arn}" \
        --stack-name "${main_stack}"
    return 0
}

function delete_configuration(){
    # --delete_configuration    Delete configuration stack 
    # this will fail if stacks depend on it

    # exit on error
    trap error ERR

    # output account used in this deployment
    account

    configuration_stack="${STACKNAME}-Configuration"
    main_stack="${STACKNAME}-Main"

    outputs=$(aws cloudformation describe-stacks ${PROFILE_STR} \
        --stack-name "${main_stack}" 2>/dev/null || true)
    [ ! -z "${outputs}" ] && error "Cant delete because MainStack still exists"

    # Retrieve key items created by the configuration stack
    bucket=$(get_bucket "${configuration_stack}")

    # delete configuration stack
    if [ ! -z "${bucket}" ];then
        aws s3 rm s3://"${bucket}" --recursive ${PROFILE_STR} || return 1
        aws s3 rb s3://"${bucket}" --force ${PROFILE_STR} || return 1
    fi
    aws cloudformation delete-stack ${PROFILE_STR} \
        --stack-name "${configuration_stack}"
    return 0
}


function status(){
    # --status  Retrieve status of stack
    # exit on error
    trap error ERR

    # output account used in this deployment
    account

    configuration_stack="${STACKNAME}-Configuration"
    main_stack="${STACKNAME}-Main"

    outputs=$(aws sts get-caller-identity ${PROFILE_STR})

    set +x
    # configuration_stack --allowed to fail if not exist
    outputs=$(aws cloudformation describe-stacks ${PROFILE_STR} \
        --stack-name "${configuration_stack}" 2>/dev/null || true)
    if [ ! -z "${outputs}" ];then
        echo "ConfigurationStack:"
        echo "${outputs}" | jq
    else
        echo "No ConfigurationStack found"
    fi

    # main_stack -- allowed to fail if not exist
    outputs=$(aws cloudformation describe-stacks ${PROFILE_STR} \
        --stack-name "${main_stack}" 2>/dev/null || true)
    if [ ! -z "${outputs}" ];then
        echo "MainStack:"
        echo "${outputs}" | jq
    else
        echo "No MainStack found"
    fi

    # re-enable verbosity
    set -x
    return 0
}

function deploy(){
    # --deploy  Deploy or Update stack
    # exit on error
    trap error ERR

    # output account used in this deployment
    account

    # Ensure current path is correct -- relative paths are used in this function
    cd "${SCRIPTPATH}" || return 1

    configuration_stack="${STACKNAME}-Configuration"
    main_stack="${STACKNAME}-Main"

    # deploy configuration stack (includes S3 Bucket, CloudFormation Role)
    deploy_configuration "${configuration_stack}"

    # if GITURL is used, fetch and checkout repository, update TEMPLATE_FILE
    if [ ! -z "${GITURL}" ];then
        update_from_git "${GITURL}" || error "Repository pull failed"
        export TEMPLATE_FILE="build/current/${TEMPLATE_FILE}"
    fi

    # Retrieve key items created by the configuration stack
    bucket=$(get_bucket "${configuration_stack}")
    bucket_url=$(get_bucket_url "${configuration_stack}")
    role_arn=$(get_role_arn "${configuration_stack}")

    # Copy or update files in S3 bucket created by the configuration stack
    aws s3 sync ${PROFILE_STR} \
        "cloudformation" \
        s3://"${bucket}/cloudformation"

    # deploy main_stack
    aws cloudformation deploy ${PROFILE_STR} \
        --template-file "${TEMPLATE_FILE}" \
        --role-arn "${role_arn}" \
        --stack-name "${main_stack}" \
        --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND \
        --parameter-overrides \
            S3BucketName="${bucket}" \
            S3BucketSecureURL="${bucket_url}/cloudformation" \
            IAMServiceRole="${role_arn}" \
            LastChange=`date +%Y%m%d%H%M%S`

    # Get stackoutputs of MainStack -- allow jq to fail if none are found
    outputs=$(\
        aws cloudformation describe-stacks ${PROFILE_STR} \
            --stack-name "${main_stack}" \
        |(jq '.Stacks[0].Outputs[] | {"\(.OutputKey)": .OutputValue}' 2>/dev/null \
          || echo "{}") \
        |jq -s add
    )

    # disable verbosity to get clean output
    set +x
    echo "Finished succesfully! Outputs of MainStack:"
    echo "${outputs}" | jq
}

function set_defaults(){
    # Ensure essential variables are set

    # Path from where this script runs -- ensure its not empty
    SCRIPTPATH=$(cd $(dirname "${BASH_SOURCE[0]}" || error "Cant retrieve directory") \
                 && pwd || return 1)
    [ ! -z "${SCRIPTPATH}" ] && export SCRIPTPATH="${SCRIPTPATH}" || return 1

    # Optional. If environment file is passed, load variables from file
    environment_file="${1}"
    if [ ! -z "${environment_file}" ];then
        if [ -s "${environment_file}" ];then
            echo "Loading: ${environment_file}"
            # - source relevant variables -- AWS_* and vars that can be overriden
            # - stick with sed to limit script dependencies
            export $(sed -n \
                '/^AWS_[A-Z_]*=.*$/p;
                /^STACKNAME=.*$/p;
                /^GITURL=.*$/p;
                /^TEMPLATE_FILE=.*$/p'
                "${environment_file}" \
            )
        else
            echo "File \"${environment_file}\" is empty or does not exist"
        fi
    fi

    # TEMPLATE_FILE: main template called to run (main) rootstack
    # default: path lookup from current scriptpath (./ -- where this script runs)
    # when GITURL is definied: path is ./build/current/${TEMPLATE_FILE}
    [ -z "${TEMPLATE_FILE}" ] && export TEMPLATE_FILE="cloudformation/main.yaml"

    # STACKNAME set in environment file, defaults to basename of scriptpath
    # additional processing to ensure compatibility with AWS Stack naming scheme
    if [ -z "${STACKNAME}" ];then
        export STACKNAME=$(process_stackname "$(basename "${SCRIPTPATH}")")
    else
        export STACKNAME=$(process_stackname "${STACKNAME}")
    fi

    # Copy AWS_DEFAULT_PROFILE TO AWS_PROFILE, if former exists and latter is unset
    [ -z "${AWS_PROFILE}" ] && [ ! -z ${AWS_DEFAULT_PROFILE} ] \
        && export AWS_PROFILE=${AWS_DEFAULT_PROFILE}

    # PROFILE_STR is added if AWS_PROFILE is set
    # while AWS CLI default behavior is to pickup from environment,
    # adding to every command makes profile usage explicit in logging
    if [ ! -z "${AWS_PROFILE}" ];then
        export PROFILE_STR="--profile \"${AWS_PROFILE}\""
    else
        export PROFILE_STR=""
    fi

    # ensure a default region is set
    [ -z "${AWS_DEFAULT_REGION}" ] && export AWS_DEFAULT_REGION=eu-west-1
    return 0
}

function check_dependencies(){
    # Verify prerequisite tools
    for tool in ${DEPENDENCIES};do
        command -v ${tool} || error "${tool} not installed"
    done
}

# see --help for <actions>, environmentfile is optional
action="${1}"
environment_file="${2}"

# verify prerequisite tools first
check_dependencies

# ensure essential variables are set in environment
set_defaults "${environment_file}"

case "${action}" in
    --deploy)   deploy; exitcode=$?;;
    --delete)   delete; exitcode=$?;;
    --delete_configuration)
                delete_configuration; exitcode=$?;;
    --status)   status; exitcode=$?;;
    --account)  account; exitcode=$?;;
    --help)     usage; exitcode=$?;;
    *)  usage; exitcode=1;;
esac

exit ${exitcode}
