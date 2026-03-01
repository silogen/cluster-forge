#!/bin/bash

# Debug script to check current cluster state for bootstrap troubleshooting

set -euo pipefail

echo "🔍 ClusterForge Bootstrap Debug Report"
echo "========================================"
echo

# Check basic cluster connectivity
echo "📡 Cluster Connectivity:"
if kubectl auth can-i get pods >/dev/null 2>&1; then
    echo "  ✅ Kubectl access: Working"
else
    echo "  ❌ Kubectl access: Failed"
    echo "     Please check kubeconfig and cluster connectivity"
    exit 1
fi

# Check namespaces
echo
echo "📦 Namespaces:"
for ns in argocd cf-gitea cf-openbao; do
    if kubectl get namespace "$ns" >/dev/null 2>&1; then
        echo "  ✅ $ns: Exists"
    else
        echo "  ❌ $ns: Missing"
    fi
done

# Check ArgoCD CRDs
echo
echo "🔧 ArgoCD CRDs:"
if kubectl get crd applications.argoproj.io >/dev/null 2>&1; then
    echo "  ✅ applications.argoproj.io: Available"
else
    echo "  ❌ applications.argoproj.io: Missing"
    echo "     ArgoCD must be deployed first"
fi

# Check ArgoCD deployment
echo
echo "⚙️  ArgoCD Deployment:"
if kubectl get namespace argocd >/dev/null 2>&1; then
    argocd_pods=$(kubectl get pods -n argocd --no-headers 2>/dev/null | wc -l || echo "0")
    ready_pods=$(kubectl get pods -n argocd --no-headers 2>/dev/null | grep -c "Running" || echo "0")
    echo "  📊 Pods: $ready_pods/$argocd_pods running"
    
    if [ "$argocd_pods" -gt 0 ]; then
        echo "  📋 Pod Status:"
        kubectl get pods -n argocd --no-headers 2>/dev/null | while read pod status ready age; do
            if [ "$status" = "Running" ]; then
                echo "    ✅ $pod: $status"
            else
                echo "    ❌ $pod: $status"
            fi
        done
    fi
else
    echo "  ❌ ArgoCD namespace not found"
fi

# Check Gitea deployment
echo
echo "📚 Gitea Deployment:"
if kubectl get namespace cf-gitea >/dev/null 2>&1; then
    gitea_pods=$(kubectl get pods -n cf-gitea --no-headers 2>/dev/null | wc -l || echo "0")
    ready_gitea=$(kubectl get pods -n cf-gitea --no-headers 2>/dev/null | grep -c "Running" || echo "0")
    echo "  📊 Pods: $ready_gitea/$gitea_pods running"
else
    echo "  ❌ Gitea namespace not found"
fi

# Check OpenBao deployment
echo
echo "🔐 OpenBao Deployment:"
if kubectl get namespace cf-openbao >/dev/null 2>&1; then
    openbao_pods=$(kubectl get pods -n cf-openbao --no-headers 2>/dev/null | wc -l || echo "0")
    ready_openbao=$(kubectl get pods -n cf-openbao --no-headers 2>/dev/null | grep -c "Running" || echo "0")
    echo "  📊 Pods: $ready_openbao/$openbao_pods running"
    
    # Check specifically for openbao-0 readiness
    if kubectl get pod openbao-0 -n cf-openbao >/dev/null 2>&1; then
        ready_status=$(kubectl get pod openbao-0 -n cf-openbao -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' || echo "Unknown")
        if [ "$ready_status" = "True" ]; then
            echo "  ✅ openbao-0: Ready"
        else
            echo "  ❌ openbao-0: Not Ready"
            echo "     This is the original issue - OpenBao readiness probe failing"
        fi
    fi
else
    echo "  ❌ OpenBao namespace not found"
fi

# Check ArgoCD Applications
echo
echo "📱 ArgoCD Applications:"
if kubectl get crd applications.argoproj.io >/dev/null 2>&1 && kubectl get namespace argocd >/dev/null 2>&1; then
    apps=$(kubectl get applications -n argocd --no-headers 2>/dev/null | wc -l || echo "0")
    if [ "$apps" -gt 0 ]; then
        echo "  📊 Found $apps applications:"
        kubectl get applications -n argocd --no-headers 2>/dev/null | while read name health sync; do
            if [ "$health" = "Healthy" ] && [ "$sync" = "Synced" ]; then
                echo "    ✅ $name: $health/$sync"
            else
                echo "    ❌ $name: $health/$sync"
            fi
        done
    else
        echo "  📊 No applications found"
        echo "     This suggests cluster-forge parent app was not created"
    fi
else
    echo "  ❌ Cannot check applications (ArgoCD not ready)"
fi

echo
echo "📋 Recommendations:"
if ! kubectl get crd applications.argoproj.io >/dev/null 2>&1; then
    echo "  🔄 Re-run bootstrap to deploy ArgoCD first"
    echo "     ./scripts/bootstrap.sh <domain> --cluster-size=<size>"
elif [ "$apps" -eq 0 ]; then
    echo "  🔄 Create cluster-forge parent application"
    echo "     ./scripts/bootstrap.sh <domain> --cluster-size=<size> --apps=cluster-forge"
else
    echo "  ✅ Bootstrap appears to be in progress"
    echo "     Check individual application sync status in ArgoCD UI"
fi

echo
echo "🔚 Debug report complete"