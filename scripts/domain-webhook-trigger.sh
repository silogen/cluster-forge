#!/bin/bash

# Domain Update Webhook Trigger Script
# Provides webhook endpoint functionality for triggering domain updates

WEBHOOK_URL="${1:-}"
DOMAIN="${2:-}"
AUTH_TOKEN="${3:-}"

show_help() {
    cat <<EOF
Domain Update Webhook Trigger

Usage: $0 <webhook-url> <domain> [auth-token]

Examples:
  # Trigger via webhook with auth token
  $0 https://webhook.cluster-domain.com/trigger-domain-update new-domain.com \$TOKEN

  # Trigger via local webhook service (port-forward)
  kubectl port-forward svc/domain-update-webhook -n cf-system 8080:8080 &
  $0 http://localhost:8080/trigger-domain-update new-domain.com

  # Check webhook status
  $0 https://webhook.cluster-domain.com/domain-update/status "" \$TOKEN

Options:
  webhook-url    Target webhook endpoint URL
  domain        New domain to update to (or empty for status check)
  auth-token    Authentication token for webhook (if required)

This script sends HTTP requests to the domain update webhook service
to trigger immediate domain updates without waiting for ArgoCD polling.
EOF
}

if [ $# -lt 1 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    show_help
    exit 0
fi

if [ -z "$WEBHOOK_URL" ]; then
    echo "ERROR: Webhook URL is required"
    show_help
    exit 1
fi

# Function to make HTTP request with optional auth
make_request() {
    local url="$1"
    local method="$2"
    local data="$3"
    local auth_token="$4"
    
    local curl_args=()
    curl_args+=("-s" "-w" "%{http_code}")
    
    if [ -n "$auth_token" ]; then
        curl_args+=("-H" "Authorization: Bearer $auth_token")
    fi
    
    if [ "$method" = "POST" ] && [ -n "$data" ]; then
        curl_args+=("-X" "$method" "-H" "Content-Type: application/json" "-d" "$data")
    else
        curl_args+=("-X" "$method")
    fi
    
    curl_args+=("$url")
    
    curl "${curl_args[@]}"
}

# Function to trigger domain update via webhook
trigger_update() {
    local webhook_url="$1"
    local domain="$2"
    local auth_token="$3"
    
    if [ -z "$domain" ]; then
        echo "ERROR: Domain is required for update trigger"
        exit 1
    fi
    
    echo "Triggering domain update via webhook..."
    echo "Webhook URL: $webhook_url"
    echo "Target Domain: $domain"
    
    local payload=$(cat <<EOF
{
    "domain": "$domain",
    "force": false,
    "trigger_type": "webhook",
    "notify_channels": ["webhook"],
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
)
    
    local response
    response=$(make_request "$webhook_url" "POST" "$payload" "$auth_token")
    local http_code="${response: -3}"
    local response_body="${response%???}"
    
    echo ""
    echo "Response Code: $http_code"
    
    case $http_code in
        200|201|202)
            echo "✓ Domain update triggered successfully"
            if [ -n "$response_body" ]; then
                echo "Response: $response_body"
            fi
            ;;
        400)
            echo "✗ Bad Request - Check domain format and payload"
            echo "Response: $response_body"
            exit 1
            ;;
        401)
            echo "✗ Unauthorized - Check authentication token"
            exit 1
            ;;
        403)
            echo "✗ Forbidden - Insufficient permissions"
            exit 1
            ;;
        404)
            echo "✗ Not Found - Check webhook URL"
            exit 1
            ;;
        500)
            echo "✗ Internal Server Error - Check webhook service logs"
            echo "Response: $response_body"
            exit 1
            ;;
        000)
            echo "✗ Connection Failed - Check webhook URL and network connectivity"
            exit 1
            ;;
        *)
            echo "✗ Unexpected response code: $http_code"
            echo "Response: $response_body"
            exit 1
            ;;
    esac
}

# Function to check webhook status
check_status() {
    local webhook_url="$1"
    local auth_token="$2"
    
    # Construct status URL
    local status_url
    if [[ "$webhook_url" == */trigger-domain-update ]]; then
        status_url="${webhook_url%/trigger-domain-update}/status"
    elif [[ "$webhook_url" == */trigger-domain-update/ ]]; then
        status_url="${webhook_url%/trigger-domain-update/}status"
    else
        status_url="$webhook_url/status"
    fi
    
    echo "Checking webhook status..."
    echo "Status URL: $status_url"
    
    local response
    response=$(make_request "$status_url" "GET" "" "$auth_token")
    local http_code="${response: -3}"
    local response_body="${response%???}"
    
    echo ""
    echo "Response Code: $http_code"
    
    case $http_code in
        200)
            echo "✓ Webhook service is healthy"
            if [ -n "$response_body" ]; then
                echo "Status: $response_body"
            fi
            ;;
        *)
            echo "✗ Webhook service is not responding properly"
            echo "Response: $response_body"
            exit 1
            ;;
    esac
}

# Function to set up port forwarding for local testing
setup_port_forward() {
    echo "Setting up port forwarding for local webhook testing..."
    echo "This will forward local port 8080 to the domain-update-webhook service."
    echo ""
    echo "Run this command in a separate terminal:"
    echo "  kubectl port-forward svc/domain-update-webhook -n cf-system 8080:8080"
    echo ""
    echo "Then use this webhook URL:"
    echo "  http://localhost:8080/trigger-domain-update"
    echo ""
    echo "Example usage:"
    echo "  $0 http://localhost:8080/trigger-domain-update new-domain.com"
}

# Function to create webhook secret for authentication
create_webhook_secret() {
    local secret_value="$1"
    
    if [ -z "$secret_value" ]; then
        secret_value=$(openssl rand -hex 32)
        echo "Generated webhook secret: $secret_value"
    fi
    
    echo "Creating webhook authentication secret..."
    
    kubectl create secret generic domain-webhook-secret \
        --from-literal=secret="$secret_value" \
        --namespace=cf-system \
        --dry-run=client -o yaml | kubectl apply -f -
    
    if [ $? -eq 0 ]; then
        echo "✓ Webhook secret created/updated in cf-system namespace"
        echo "Use this token for webhook authentication: $secret_value"
    else
        echo "✗ Failed to create webhook secret"
        exit 1
    fi
}

# Main execution logic
main() {
    case "${WEBHOOK_URL}" in
        "setup-port-forward")
            setup_port_forward
            ;;
        "create-secret")
            create_webhook_secret "$DOMAIN"
            ;;
        */status|*/health)
            check_status "$WEBHOOK_URL" "$AUTH_TOKEN"
            ;;
        *)
            if [ -z "$DOMAIN" ]; then
                # If no domain provided, check status
                check_status "$WEBHOOK_URL" "$AUTH_TOKEN"
            else
                # Trigger update
                trigger_update "$WEBHOOK_URL" "$DOMAIN" "$AUTH_TOKEN"
            fi
            ;;
    esac
}

# Execute main function
main "$@"