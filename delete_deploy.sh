#!/bin/bash

echo "Enter the namespace name where the deployment is:"
read NAMESPACE

kubectl delete deployment hemant-deployment -n $NAMESPACE

echo "Deployment hemant-deployment deleted from namespace $NAMESPACE."