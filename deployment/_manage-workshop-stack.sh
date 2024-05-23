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

        echo "Deleting code build log group"
        aws logs delete-log-group --log-group-name "/aws/codebuild/install-stack-codebuild"
        echo "Deleted code build log group"
    else
        echo "Invalid stack operation!"
        exit 1
    fi
}
