#!/bin/bash -x
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

## Defines workshop configuration shared amongst various scripts

## Variables for the workshop
WORKSHOP_NAME="Wiggleworm"
REPO_NAME=$(echo $REPO_URL|sed 's#.*/##'|sed 's/\.git//')
CDK_VERSION="2.142.1"
C9_ATTR_ARN_PARAMETER_NAME="/"$WORKSHOP_NAME"/Cloud9/AttrArn"
C9_INSTANCE_PROFILE_PARAMETER_NAME="/"$WORKSHOP_NAME"/Cloud9/InstanceProfileName"
TARGET_USER="ec2-user"
CDK_C9_STACK=$(echo ${WORKSHOP_NAME}|sed "s/[^A-Za-z0-9]//g")"-9Stack"

##  Helper functions
# Try to run a command 3 times then timeout
function retry {
  local n=1
  local max=3
  local delay=10
  while true; do
    "$@" && break || {
      if [[ $n -lt $max ]]; then
        ((n++))
        echo "Command failed. Attempt $n/$max:"
        sleep $delay;
      else
        echo "The command has failed after $n attempts."
        exit 1
      fi
    }
  done
}

# Run an SSM command on an EC2 instance
run_ssm_command() {
    SSM_COMMAND="$1"
    parameters=$(jq -n --arg cm "runuser -l \"$TARGET_USER\" -c \"$SSM_COMMAND\"" '{executionTimeout:["3600"], commands: [$cm]}')
    comment=$(echo "$SSM_COMMAND" | cut -c1-100)
    # send ssm command to instance id in C9_ID
    sh_command_id=$(aws ssm send-command \
        --targets "Key=InstanceIds,Values=$C9_ID" \
        --document-name "AWS-RunShellScript" \
        --parameters "$parameters" \
        --timeout-seconds 3600 \
        --comment "$comment" \
        --output text \
        --query "Command.CommandId")

    command_status="InProgress" # seed status var
    while [[ "$command_status" == "InProgress" || "$command_status" == "Pending" || "$command_status" == "Delayed" ]]; do
        sleep 15
        command_invocation=$(aws ssm get-command-invocation \
            --command-id "$sh_command_id" \
            --instance-id "$C9_ID")
        echo -E "$command_invocation" | jq # for debugging purposes
        command_status=$(echo -E "$command_invocation" | jq -r '.Status')
    done

    if [ "$command_status" != "Success" ]; then
        echo "failed executing $SSM_COMMAND : $command_status" && exit 1
    else
        echo "successfully completed execution!"
    fi
}

# Wait for an EC2 instance to become available and for it to be online in SSM
wait_for_instance_ssm() {
    INSTANCE_ID="$1"
    echo "Waiting for instance $INSTANCE_ID to become available"
    aws ec2 wait instance-status-ok --instance-ids "$INSTANCE_ID"
    echo "Instance $INSTANCE_ID is available"
    ssm_status=$(aws ssm describe-instance-information --filters "Key=InstanceIds,Values=$INSTANCE_ID" --query 'InstanceInformationList[].PingStatus' --output text)
    while [[ "$ssm_status" != "Online" ]]; do
        echo "Instance $INSTANCE_ID is not online in SSM yet. Waiting 15 seconds"
        sleep 15
        ssm_status=$(aws ssm describe-instance-information --filters "Key=InstanceIds, Values=$INSTANCE_ID" --query 'InstanceInformationList[].PingStatus' --output text)
    done
    echo "Instance $INSTANCE_ID is online in SSM"
}

# Replace an instance profile on an EC2 instance
replace_instance_profile() {
    echo "Replacing instance profile"
    association_id=$(aws ec2 describe-iam-instance-profile-associations --filter "Name=instance-id,Values=$C9_ID" --query 'IamInstanceProfileAssociations[].AssociationId' --output text)
    if [ ! association_id == "" ]; then
        aws ec2 disassociate-iam-instance-profile --association-id $association_id
        command_status=$(aws ec2 describe-iam-instance-profile-associations --filter "Name=instance-id,Values=$C9_ID" --query 'IamInstanceProfileAssociations[].State' --output text)
        while [[ "$command_status" == "disassociating" ]]; do
            sleep 15
            command_status=$(aws ec2 describe-iam-instance-profile-associations --filter "Name=instance-id,Values=$C9_ID" --query 'IamInstanceProfileAssociations[].State' --output text)
        done
    fi
    aws ec2 associate-iam-instance-profile --instance-id $C9_ID --iam-instance-profile Name=$C9_INSTANCE_PROFILE_NAME
    command_status=$(aws ec2 describe-iam-instance-profile-associations --filter "Name=instance-id,Values=$C9_ID" --query 'IamInstanceProfileAssociations[].State' --output text)
    while [[ "$command_status" == "associating" ]]; do
        sleep 15
        command_status=$(aws ec2 describe-iam-instance-profile-associations --filter "Name=instance-id,Values=$C9_ID" --query 'IamInstanceProfileAssociations[].State' --output text)
    done
    echo "Instance profile replaced. Rebooting instance"
    aws ec2 reboot-instances --instance-ids "$C9_ID"
    wait_for_instance_ssm "$C9_ID"
    echo "Instance rebooted"
}

# Get Cloud9 instance ID
get_c9_id() {
    C9_ENV_ID=$(aws ssm get-parameter \
        --name "$C9_ATTR_ARN_PARAMETER_NAME" \
        --output text \
        --query "Parameter.Value"|cut -d ":" -f 7)
    C9_ID=$(aws ec2 describe-instances \
        --filter "Name=tag:aws:cloud9:environment,Values=$C9_ENV_ID" \
        --query 'Reservations[].Instances[].{Instance:InstanceId}' \
        --output text)
}

create_workshop() {
    # Deploy cloud9 instance using CDK
    echo "Deploying CDK..."
    npm install --force --global aws-cdk@$CDK_VERSION
    cd cloud9
    npm install
    cdk bootstrap
    echo "Starting Cloud9 cdk deploy..."
    cdk deploy $CDK_C9_STACK \
        --require-approval never
    echo "Done Cloud9 cdk deploy!"

    get_c9_id

    echo "Waiting for " $C9_ID
    aws ec2 start-instances --instance-ids "$C9_ID"
    aws ec2 wait instance-status-ok --instance-ids "$C9_ID"
    echo $C9_ID "ready"

    C9_INSTANCE_PROFILE_NAME=$(aws ssm get-parameter \
        --name "$C9_INSTANCE_PROFILE_PARAMETER_NAME" \
        --output text \
        --query "Parameter.Value")
    replace_instance_profile


    run_ssm_command "cd ~/environment ; git clone --branch $REPO_BRANCH_NAME $REPO_URL || echo 'Repo already exists.'"
    run_ssm_command "rm -vf ~/.aws/credentials"
    run_ssm_command "cd ~/environment/$REPO_NAME/deployment/cloud9 && ./resize-cloud9-ebs-vol.sh"
    run_ssm_command "cd ~/environment/$REPO_NAME/deployment && ./create-workshop.sh"

}

delete_workshop() {
    get_c9_id
    if [[ "$C9_ID" != "None" ]]; then
        aws ec2 start-instances --instance-ids "$C9_ID"
        wait_for_instance_ssm "$C9_ID"
        run_ssm_command "cd ~/environment/$REPO_NAME/deployment && ./delete-workshop.sh"
    else
        cd ..
        ./delete-workshop.sh
        cd cloud9
    fi

    echo "Starting cdk destroy..."
    cdk destroy --all --force
    echo "Done cdk destroy!"
}
