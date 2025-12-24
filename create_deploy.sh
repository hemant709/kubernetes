#!/bin/bash

echo "Enter the image name (e.g., nginx:1.21):"
read IMAGE

echo "Enter the namespace name:"
read NAMESPACE

echo "Enter the number of pods (replicas):"
read REPLICAS

kubectl get ns $NAMESPACE > /dev/null 2>&1
if [ $? -ne 0 ]; then
  echo "Namespace $NAMESPACE does not exist. Creating it..."
  kubectl create ns $NAMESPACE
fi

sed -i "s/{{NAMESPACE}}/$NAMESPACE/g" deployment.yml
sed -i "s/{{REPLICAS}}/$REPLICAS/g" deployment.yml
sed -i "s/{{IMAGE}}/$IMAGE/g" deployment.yml

sed -i "s/{{NAMESPACE}}/$NAMESPACE/g" service.yml

kubectl apply -f deployment.yml
kubectl apply -f service.yml

echo "Waiting for pods to be ready..."
kubectl wait --for=condition=ready pod -l app=myapp -n $NAMESPACE --timeout=300s

kubectl port-forward svc/hemant-service -n $NAMESPACE 8080:80 &
echo "Deployment and service created in namespace $NAMESPACE with $REPLICAS pods using image $IMAGE."
echo "Access the application at http://localhost:8080"