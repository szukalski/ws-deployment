#!/bin/bash -x
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# Define workshop specific constants
# Per WORKSHOP_NAME variables
WORKSHOP_NAME="Wiggleworm"
REPO_NAME=$(echo $REPO_URL||sed 's#.*/##'|sed 's/\.git//')
CDK_VERSION="2.142.1"

# Static variables
C9_ATTR_ARN_PARAMETER_NAME="/"$WORKSHOP_NAME"/Cloud9/AttrArn"
C9_INSTANCE_PROFILE_PARAMETER_NAME="/"$WORKSHOP_NAME"/Cloud9/InstanceProfileName"
TARGET_USER="ec2-user"
CDK_C9_STACK=$WORKSHOP_NAME"-Cloud9Stack"

# Define how to manage your workshop stack
# The example below deploys a Cloud9 instance and uses it to bootstrap a workshop.
manage_workshop_stack() {
    STACK_OPERATION=$(echo "$1" | tr '[:upper:]' '[:lower:]')

    npm install --force --global aws-cdk@$CDK_VERSION

    cd cloud9
    npm install
    cdk bootstrap

    if [[ "$STACK_OPERATION" == "create" || "$STACK_OPERATION" == "update" ]]; then
        echo "Starting Cloud9 cdk deploy..."
        cdk deploy $CDK_C9_STACK \
            --require-approval never
        echo "Done Cloud9 cdk deploy!"
    fi

    C9_ENV_ID=$(aws ssm get-parameter \
        --name "$C9_ATTR_ARN_PARAMETER_NAME" \
        --output text \
        --query "Parameter.Value"|cut -d ":" -f 7)
    C9_ID=$(aws ec2 describe-instances \
        --filter "Name=tag:aws:cloud9:environment,Values=$C9_ENV_ID" \
        --query 'Reservations[].Instances[].{Instance:InstanceId}' \
        --output text)
    C9_INSTANCE_PROFILE_NAME=$(aws ssm get-parameter \
        --name "$C9_INSTANCE_PROFILE_PARAMETER_NAME" \
        --output text \
        --query "Parameter.Value")

    if [[ "$STACK_OPERATION" == "create" ]]; then
        echo "Waiting for " $C9_ID
        aws ec2 start-instances --instance-ids "$C9_ID"
        aws ec2 wait instance-status-ok --instance-ids "$C9_ID"
        echo $C9_ID "ready"
        replace_instance_profile
        run_ssm_command "cd ~/environment ; git clone --branch $REPO_BRANCH_NAME $REPO_URL || echo 'Repo already exists.'"
        run_ssm_command "rm -vf ~/.aws/credentials"
        run_ssm_command "cd ~/environment/$REPONAME/deployment/cloud9 && ./resize-cloud9-ebs-vol.sh"
        run_ssm_command "cd ~/environment/$REPONAME/deployment && ./create-workshop.sh"
        
    elif [ "$STACK_OPERATION" == "delete" ]; then

        if [[ "$C9_ID" != "None" ]]; then
            aws ec2 start-instances --instance-ids "$C9_ID"
            wait_for_instance_ssm "$C9_ID"
            run_ssm_command "cd ~/environment/$REPONAME/deployment && ./delete-workshop.sh"
        else
            cd ..
            ./destroy-workshop.sh
            cd cloud9
        fi

        echo "Starting cdk destroy..."
        cdk destroy --all --force
        echo "Done cdk destroy!"
    else
        echo "Invalid stack operation!"
        exit 1
    fi
}


STACK_OPERATION="$1"

for i in {1..3}; do
    echo "iteration number: $i"
    if manage_workshop_stack "$STACK_OPERATION"; then
        echo "successfully completed execution"
        exit 0
    else
        sleep "$((15*i))"
    fi
done

echo "failed to complete execution"
exit 1
