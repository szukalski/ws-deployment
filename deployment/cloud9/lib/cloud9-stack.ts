import * as cdk from 'aws-cdk-lib';
import { CfnEnvironmentEC2 } from 'aws-cdk-lib/aws-cloud9';
import { Vpc } from 'aws-cdk-lib/aws-ec2';
import { CompositePrincipal, InstanceProfile, ManagedPolicy, PolicyDocument, Role, ServicePrincipal } from 'aws-cdk-lib/aws-iam';
import { StringParameter } from 'aws-cdk-lib/aws-ssm';
import { Construct } from 'constructs';
import { readFileSync } from 'fs';

export interface Cloud9StackProps extends cdk.StackProps {
  workshop: string;
  ownerArn?: string;
  imageId?: string;
  instanceType?: string;
  vpc?: Vpc;
}

export class Cloud9Stack extends cdk.Stack {
  readonly c9: CfnEnvironmentEC2;
  constructor(scope: Construct, id: string, props: Cloud9StackProps) {
    super(scope, id, props);
    // Use the default VPC unless one is supplied
    const vpc =
      props?.vpc ??
      Vpc.fromLookup(this, "VPC", { isDefault: true, })
      ;
    
    // Create the Cloud9 environment
    this.c9 = new CfnEnvironmentEC2(this, 'Cloud9Stack', {
      imageId: props?.imageId ?? 'amazonlinux-2023-x86_64',
      instanceType: props?.instanceType ?? 'm5.large',
      description: props.workshop+" Cloud9",
      ownerArn: props.ownerArn,
      subnetId: vpc.publicSubnets[0].subnetId,
      automaticStopTimeMinutes: 180,
      tags: [{ key: 'Workshop', value: props.workshop }],
    });
    new StringParameter(this, 'Cloud9AttrArn', {
      parameterName: '/'+props.workshop+'/Cloud9/AttrArn',
      stringValue: this.c9.attrArn,
    });
    const policy = new ManagedPolicy(this, 'WsPolicy', {
      document: PolicyDocument.fromJson(JSON.parse(readFileSync(`${__dirname}/../../iam_policy.json`, 'utf-8'))),
    });
    const cloud9Role = new Role(this, "Cloud9Role", {
      assumedBy: new CompositePrincipal(
        new ServicePrincipal('ec2.amazonaws.com'),
        new ServicePrincipal('ssm.amazonaws.com')
      ),
      managedPolicies: [
        policy,
        ManagedPolicy.fromAwsManagedPolicyName("ReadOnlyAccess"),
      ],
    });

    const cloud9InstanceProfile = new InstanceProfile(
      this,
      "Cloud9InstanceProfile",
      {
        role: cloud9Role,
      }
    );

    const cloud9InstanceProfileName = '/'+props.workshop+'/Cloud9/InstanceProfileName';

    new StringParameter(this, "cloud9InstanceProfileNameSSMParameter", {
      parameterName: cloud9InstanceProfileName,
      stringValue: cloud9InstanceProfile.instanceProfileName,
    });
    
    
  }
}
