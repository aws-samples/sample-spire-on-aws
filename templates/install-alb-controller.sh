#!/bin/bash
set -e

CLUSTER_NAME="${CLUSTER_NAME:-$(kubectl config current-context | cut -d'/' -f2)}"
AWS_REGION="${AWS_REGION:-us-east-1}"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "=== Installing AWS Load Balancer Controller ==="
echo "Cluster: $CLUSTER_NAME"
echo "Region: $AWS_REGION"
echo "Account: $AWS_ACCOUNT_ID"

# Create IAM policy for AWS Load Balancer Controller
echo "Creating IAM policy..."
curl -o iam-policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json

aws iam create-policy \
    --policy-name AWSLoadBalancerControllerIAMPolicy \
    --policy-document file://iam-policy.json 2>/dev/null || {
    echo "Policy already exists, updating with latest version..."
    aws iam create-policy-version \
        --policy-arn arn:aws:iam::${AWS_ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy \
        --policy-document file://iam-policy.json \
        --set-as-default 2>/dev/null || echo "Policy update failed or already up to date"
}

# Create service account
echo "Creating service account..."
kubectl create namespace aws-load-balancer-controller 2>/dev/null || true

kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: aws-load-balancer-controller
  namespace: aws-load-balancer-controller
EOF

# Create IAM role for Pod Identity
echo "Creating IAM role..."
cat > trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "pods.eks.amazonaws.com"
      },
      "Action": [
        "sts:AssumeRole",
        "sts:TagSession"
      ]
    }
  ]
}
EOF

aws iam create-role \
    --role-name AmazonEKSLoadBalancerControllerRole \
    --assume-role-policy-document file://trust-policy.json 2>/dev/null || echo "Role already exists"

aws iam attach-role-policy \
    --role-name AmazonEKSLoadBalancerControllerRole \
    --policy-arn arn:aws:iam::${AWS_ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy

# Wait for IAM role propagation
echo "Waiting for IAM role propagation..."
sleep 10

# Create Pod Identity association
echo "Creating Pod Identity association..."
aws eks create-pod-identity-association \
    --cluster-name $CLUSTER_NAME \
    --namespace aws-load-balancer-controller \
    --service-account aws-load-balancer-controller \
    --role-arn arn:aws:iam::${AWS_ACCOUNT_ID}:role/AmazonEKSLoadBalancerControllerRole \
    --region $AWS_REGION || echo "Pod Identity association already exists"

# Install cert-manager
echo "Installing cert-manager..."
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.3/cert-manager.yaml
kubectl wait --for=condition=available --timeout=300s deployment/cert-manager -n cert-manager
kubectl wait --for=condition=available --timeout=300s deployment/cert-manager-webhook -n cert-manager

# Install Helm if not present
if ! command -v helm &> /dev/null; then
    echo "Installing Helm..."
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 -o /tmp/get-helm-3.sh
    bash /tmp/get-helm-3.sh
    rm -f /tmp/get-helm-3.sh
fi

# Get VPC ID from cluster
echo "Getting VPC ID..."
VPC_ID=$(aws eks describe-cluster --name $CLUSTER_NAME --region $AWS_REGION --query "cluster.resourcesVpcConfig.vpcId" --output text)

# Install AWS Load Balancer Controller using Helm
echo "Installing AWS Load Balancer Controller..."
helm repo add eks https://aws.github.io/eks-charts
helm repo update

helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n aws-load-balancer-controller \
  --set clusterName=$CLUSTER_NAME \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region=$AWS_REGION \
  --set vpcId=$VPC_ID

echo "Waiting for controller to be ready..."
kubectl wait --for=condition=available --timeout=300s deployment/aws-load-balancer-controller -n aws-load-balancer-controller

# Create IngressClass
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: IngressClass
metadata:
  name: alb
spec:
  controller: ingress.k8s.aws/alb
EOF

echo ""
echo "=== Installation Complete ==="

# Cleanup temp files
rm -f iam-policy.json trust-policy.json
