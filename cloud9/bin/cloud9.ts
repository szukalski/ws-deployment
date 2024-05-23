#!/usr/bin/env node
import 'source-map-support/register';
import * as cdk from 'aws-cdk-lib';
import { Cloud9Stack } from '../lib/cloud9-stack';

const app = new cdk.App();
const account = process.env.CDK_DEFAULT_ACCOUNT;
const region = process.env.CDK_DEFAULT_REGION;
const env = { account, region };
const participantAssumedRoleArn = process.env.PARTICIPANT_ASSUMED_ROLE_ARN;

new Cloud9Stack(app, 'WS-Cloud9Stack', {
  workshop: 'Wiggleworm',
  ownerArn: participantAssumedRoleArn,
  env: env,
});