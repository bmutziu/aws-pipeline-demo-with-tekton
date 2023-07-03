#!/bin/bash
set -e 

for tool in aws kubectl jq
do
    if ! [ -x "$(command -v $tool)" ]; then
        echo "[ERROR] $(date +"%T") $tool is not installed. Please install $tool before running the script again" >&2
        exit 1
    fi
done

export AWS_AUTHENTICATED_IDENTITY=$(aws sts get-caller-identity | jq -r .Arn | cut -d "/" -f2)
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --output text --query Account)
# export AWS_REGION=$(aws configure get region)
export AWS_REGION="eu-west-1"

# init
function pause(){
   read -p "$*"
}

while true; do
    read -p "Uninstall resources as $AWS_AUTHENTICATED_IDENTITY within account $AWS_ACCOUNT_ID in region $AWS_REGION [Y/N] " yn
    case $yn in
        [Yy]* ) break;;
        [Nn]* ) exit 1;;
        * ) echo "[ERROR] $(date +"%T") Please answer yes [Y|y] or no [N|n].";;
    esac 
done

echo "[INFO] $(date +"%T") Remove namespaces..."
kubectl -n argocd delete svc argocd-server
kubectl -n apps-build delete ingress tekton-webhook-listener
kubectl -n apps delete ingress tekton-demo-app
kubectl -n support delete ingress chartmuseum
kubectl -n tekton-pipelines delete ingress tekton-dashboard
kubectl delete namespace apps
kubectl delete namespace apps-build
kubectl delete namespace argocd

pause "remove namespaces"

echo "[INFO] $(date +"%T") Remove container repositories..."
aws ecr delete-repository --repository-name=cloner --force
aws ecr delete-repository --repository-name=maven-builder --force
aws ecr delete-repository --repository-name=tekton-demo-app --force

pause "remove container repositories"

echo "[INFO] $(date +"%T") Remove referenced security groups from cluster security group..."
export TEKTON_DEMO_CLUSTER_NODE_SG=$(aws cloudformation describe-stacks --stack-name eksctl-tekton-pipeline-demo-cluster-cluster | jq -r '.Stacks[0].Outputs[] | select(.OutputKey == "ClusterSecurityGroupId") | .OutputValue')
export TEKTON_DEMO_CHARTMUSEUM_SG=$(aws cloudformation describe-stacks --stack-name TektonDemoInfra | jq -r '.Stacks[0].Outputs[] | select(.OutputKey == "ChartmuseumSecurityGroup") | .OutputValue')
export TEKTON_DEMO_DASHBOARD_SG=$(aws cloudformation describe-stacks --stack-name TektonDemoInfra | jq -r '.Stacks[0].Outputs[] | select(.OutputKey == "DashboardSecurityGroup") | .OutputValue')
export TEKTON_DEMO_APP_SG=$(aws cloudformation describe-stacks --stack-name TektonDemoInfra | jq -r '.Stacks[0].Outputs[] | select(.OutputKey == "AppSecurityGroup") | .OutputValue')
export TEKTON_DEMO_WEBHOOK_SG=$(aws cloudformation describe-stacks --stack-name TektonDemoInfra | jq -r '.Stacks[0].Outputs[] | select(.OutputKey == "WebhookSecurityGroup") | .OutputValue')

aws ec2 revoke-security-group-ingress --group-id $TEKTON_DEMO_CLUSTER_NODE_SG --ip-permissions IpProtocol=tcp,FromPort=30000,ToPort=32767,UserIdGroupPairs=[{GroupId=$TEKTON_DEMO_DASHBOARD_SG}]
aws ec2 revoke-security-group-ingress --group-id $TEKTON_DEMO_CLUSTER_NODE_SG --ip-permissions IpProtocol=tcp,FromPort=30000,ToPort=32767,UserIdGroupPairs=[{GroupId=$TEKTON_DEMO_APP_SG}]
aws ec2 revoke-security-group-ingress --group-id $TEKTON_DEMO_CLUSTER_NODE_SG --ip-permissions IpProtocol=tcp,FromPort=30000,ToPort=32767,UserIdGroupPairs=[{GroupId=$TEKTON_DEMO_WEBHOOK_SG}]
aws ec2 revoke-security-group-ingress --group-id $TEKTON_DEMO_CLUSTER_NODE_SG --ip-permissions IpProtocol=tcp,FromPort=30000,ToPort=32767,UserIdGroupPairs=[{GroupId=$TEKTON_DEMO_CHARTMUSEUM_SG}]

pause "remove referenced security groups from cluster security group"

echo "[INFO] $(date +"%T") Delete <<TektonDemoInfra>> Cloudformation stack..."
aws cloudformation delete-stack --stack-name TektonDemoInfra
aws cloudformation wait stack-delete-complete --stack-name TektonDemoInfra

pause "delete <<TektonDemoInfra>> Cloudformation stack"

echo "[INFO] $(date +"%T") Delete EKS IAM Configuration..."
eksctl delete iamserviceaccount --config-file=eks-cluster-iam-config.yaml --approve

pause "delete EKS IAM Configuration"

echo "[INFO] $(date +"%T") Empty buckets..."
export TEKTON_DEMO_CHARTMUSEUM_BUCKET=$(aws cloudformation describe-stacks --stack-name TektonDemoBuckets | jq -r '.Stacks[0].Outputs[] | select(.OutputKey == "ChartmuseumBucket") | .OutputValue')
aws s3 rm s3://${TEKTON_DEMO_CHARTMUSEUM_BUCKET} --recursive
export TEKTON_DEMO_CODE_BUCKET=$(aws cloudformation describe-stacks --stack-name TektonDemoBuckets | jq -r '.Stacks[0].Outputs[] | select(.OutputKey == "CodeBucket") | .OutputValue')
aws s3 rm s3://${TEKTON_DEMO_CODE_BUCKET} --recursive

pause "empty buckets"

echo "[INFO] $(date +"%T") Delete <<TektonDemoBuckets>> Cloudformation stack..."
aws cloudformation delete-stack --stack-name TektonDemoBuckets
aws cloudformation wait stack-delete-complete --stack-name TektonDemoBuckets

pause "delete <<TektonDemoBuckets>> Cloudformation stack"

echo "[INFO] $(date +"%T") Delete Git credentials..."
export AWS_AUTHENTICATED_IDENTITY=$(aws sts get-caller-identity | jq -r .Arn | cut -d "/" -f2)
export AWS_GIT_CREDENTIAL_ID=$(aws iam list-service-specific-credentials --user-name $AWS_AUTHENTICATED_IDENTITY --service-name codecommit.amazonaws.com | jq -r .ServiceSpecificCredentials[0].ServiceSpecificCredentialId)
aws iam delete-service-specific-credential --service-specific-credential-id $AWS_GIT_CREDENTIAL_ID

pause "delete Git credentials"

echo "[INFO] $(date +"%T") Delete helm charts and tekton workloads ..."

helm -n kube-system uninstall aws-load-balancer-controller
helm -n kube-system uninstall aws-ebs-csi-driver
helm -n support uninstall chartmuseum
helm -n default uninstall $(helm list -n default -q)
helm list -A

export TEKTON_PIPELINE_VERSION="v0.47.3"
export TEKTON_TRIGGERS_VERSION="v0.24.1"
export TEKTON_DASHBOARD_VERSION="v0.37.0"
kubectl delete --filename https://storage.googleapis.com/tekton-releases/dashboard/previous/${TEKTON_DASHBOARD_VERSION}/release.yaml
kubectl delete --filename https://storage.googleapis.com/tekton-releases/triggers/previous/${TEKTON_TRIGGERS_VERSION}/interceptors.yaml
kubectl delete --filename https://storage.googleapis.com/tekton-releases/triggers/previous/${TEKTON_TRIGGERS_VERSION}/release.yaml
kubectl delete --filename https://storage.googleapis.com/tekton-releases/pipeline/previous/${TEKTON_PIPELINE_VERSION}/release.yaml

echo "[INFO] $(date +"%T") Cleanup successfully completed..."
