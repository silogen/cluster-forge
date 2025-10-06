package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"strings"
	"time"

	authv3 "github.com/envoyproxy/go-control-plane/envoy/service/auth/v3"
	typev3 "github.com/envoyproxy/go-control-plane/envoy/type/v3"
	corev3 "github.com/envoyproxy/go-control-plane/envoy/config/core/v3"
	"google.golang.org/genproto/googleapis/rpc/code"
	"google.golang.org/genproto/googleapis/rpc/status"
	"google.golang.org/grpc"
	"google.golang.org/grpc/reflection"
)

const (
	// Default configuration
	defaultPort        = "9000"
	defaultOpenBaoAddr = "http://openbao.default.svc.cluster.local:8200"
	apiKeyHeader       = "x-api-key"
	authHeader         = "authorization"
)

// OpenBaoResponse represents the response from OpenBao API
type OpenBaoResponse struct {
	Data struct {
		Data struct {
			Key         string    `json:"key"`
			User        string    `json:"user"`
			Active      bool      `json:"active"`
			CreatedAt   string    `json:"created_at"`
			ExpiresAt   string    `json:"expires_at"`
			Permissions []string  `json:"permissions"`
		} `json:"data"`
	} `json:"data"`
}

// AuthServer implements the ExtAuth service
type AuthServer struct {
	authv3.UnimplementedAuthorizationServer
	openBaoAddr  string
	openBaoToken string
	httpClient   *http.Client
}

// NewAuthServer creates a new AuthServer instance
func NewAuthServer() *AuthServer {
	openBaoAddr := getEnv("OPENBAO_ADDR", defaultOpenBaoAddr)
	openBaoToken := getEnv("OPENBAO_TOKEN", "")
	
	if openBaoToken == "" {
		log.Fatal("OPENBAO_TOKEN environment variable is required")
	}

	return &AuthServer{
		openBaoAddr:  openBaoAddr,
		openBaoToken: openBaoToken,
		httpClient: &http.Client{
			Timeout: 10 * time.Second,
		},
	}
}

// Check implements the authorization check
func (a *AuthServer) Check(ctx context.Context, req *authv3.CheckRequest) (*authv3.CheckResponse, error) {
	// Extract headers from the request
	headers := req.GetAttributes().GetRequest().GetHttp().GetHeaders()
	
	log.Printf("Received auth request for: %s %s", 
		req.GetAttributes().GetRequest().GetHttp().GetMethod(),
		req.GetAttributes().GetRequest().GetHttp().GetPath())

	// Extract API key from headers
	apiKey := extractAPIKey(headers)
	if apiKey == "" {
		log.Printf("No API key found in request headers")
		return a.denyResponse("Missing API key"), nil
	}

	log.Printf("Validating API key: %s...", apiKey[:min(8, len(apiKey))])

	// Validate API key against OpenBao
	valid, userInfo, err := a.validateAPIKey(ctx, apiKey)
	if err != nil {
		log.Printf("Error validating API key: %v", err)
		return a.denyResponse("Internal error"), nil
	}

	if !valid {
		log.Printf("Invalid API key: %s...", apiKey[:min(8, len(apiKey))])
		return a.denyResponse("Invalid API key"), nil
	}

	log.Printf("API key validated successfully for user: %s", userInfo.User)

	// Return success response with user info
	return a.allowResponse(userInfo), nil
}

// extractAPIKey extracts the API key from request headers
func extractAPIKey(headers map[string]string) string {
	// Check X-API-Key header first
	if apiKey := headers[apiKeyHeader]; apiKey != "" {
		return apiKey
	}

	// Check Authorization header for Bearer token
	if authValue := headers[authHeader]; authValue != "" {
		if strings.HasPrefix(strings.ToLower(authValue), "bearer ") {
			return strings.TrimPrefix(authValue, "Bearer ")
		}
		if strings.HasPrefix(strings.ToLower(authValue), "bearer ") {
			return strings.TrimPrefix(authValue, "bearer ")
		}
	}

	return ""
}

// UserInfo holds validated user information
type UserInfo struct {
	User        string
	Permissions []string
	ExpiresAt   string
}

// validateAPIKey validates the API key against OpenBao
func (a *AuthServer) validateAPIKey(ctx context.Context, apiKey string) (bool, *UserInfo, error) {
	// Construct OpenBao API URL
	url := fmt.Sprintf("%s/v1/api-keys/data/%s", a.openBaoAddr, apiKey)

	// Create request
	req, err := http.NewRequestWithContext(ctx, "GET", url, nil)
	if err != nil {
		return false, nil, fmt.Errorf("creating request: %w", err)
	}

	// Add OpenBao token
	req.Header.Set("X-Vault-Token", a.openBaoToken)

	// Make request
	resp, err := a.httpClient.Do(req)
	if err != nil {
		return false, nil, fmt.Errorf("making request to OpenBao: %w", err)
	}
	defer resp.Body.Close()

	// Check response status
	if resp.StatusCode == http.StatusNotFound {
		return false, nil, nil // API key not found
	}

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return false, nil, fmt.Errorf("OpenBao returned status %d: %s", resp.StatusCode, string(body))
	}

	// Parse response
	var openBaoResp OpenBaoResponse
	if err := json.NewDecoder(resp.Body).Decode(&openBaoResp); err != nil {
		return false, nil, fmt.Errorf("decoding OpenBao response: %w", err)
	}

	keyData := openBaoResp.Data.Data

	// Check if key is active
	if !keyData.Active {
		log.Printf("API key is inactive: %s", keyData.Key)
		return false, nil, nil
	}

	// Check if key is expired
	if keyData.ExpiresAt != "" {
		expiresAt, err := time.Parse(time.RFC3339, keyData.ExpiresAt)
		if err != nil {
			log.Printf("Warning: could not parse expiration time %s: %v", keyData.ExpiresAt, err)
		} else if time.Now().After(expiresAt) {
			log.Printf("API key is expired: %s (expired at %s)", keyData.Key, keyData.ExpiresAt)
			return false, nil, nil
		}
	}

	userInfo := &UserInfo{
		User:        keyData.User,
		Permissions: keyData.Permissions,
		ExpiresAt:   keyData.ExpiresAt,
	}

	return true, userInfo, nil
}

// allowResponse creates a successful authorization response
func (a *AuthServer) allowResponse(userInfo *UserInfo) *authv3.CheckResponse {
	// Add user info as headers to be passed to the backend service
	headers := []*corev3.HeaderValueOption{
		{
			Header: &corev3.HeaderValue{
				Key:   "x-user-id",
				Value: userInfo.User,
			},
		},
		{
			Header: &corev3.HeaderValue{
				Key:   "x-user-permissions",
				Value: strings.Join(userInfo.Permissions, ","),
			},
		},
	}

	if userInfo.ExpiresAt != "" {
		headers = append(headers, &corev3.HeaderValueOption{
			Header: &corev3.HeaderValue{
				Key:   "x-token-expires-at",
				Value: userInfo.ExpiresAt,
			},
		})
	}

	return &authv3.CheckResponse{
		Status: &status.Status{
			Code: int32(code.Code_OK),
		},
		HttpResponse: &authv3.CheckResponse_OkResponse{
			OkResponse: &authv3.OkHttpResponse{
				Headers: headers,
			},
		},
	}
}

// denyResponse creates a denial authorization response
func (a *AuthServer) denyResponse(reason string) *authv3.CheckResponse {
	return &authv3.CheckResponse{
		Status: &status.Status{
			Code:    int32(code.Code_UNAUTHENTICATED),
			Message: reason,
		},
		HttpResponse: &authv3.CheckResponse_DeniedResponse{
			DeniedResponse: &authv3.DeniedHttpResponse{
				Status: &typev3.HttpStatus{
					Code: typev3.StatusCode_Unauthorized,
				},
				Body: fmt.Sprintf(`{"error": "%s"}`, reason),
				Headers: []*corev3.HeaderValueOption{
					{
						Header: &corev3.HeaderValue{
							Key:   "content-type",
							Value: "application/json",
						},
					},
				},
			},
		},
	}
}

// getEnv gets an environment variable with a default value
func getEnv(key, defaultValue string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return defaultValue
}

// min returns the minimum of two integers
func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}

func main() {
	port := getEnv("PORT", defaultPort)
	
	log.Printf("Starting OpenBao ExtAuth service on port %s", port)
	log.Printf("OpenBao address: %s", getEnv("OPENBAO_ADDR", defaultOpenBaoAddr))

	// Create gRPC server
	server := grpc.NewServer()
	
	// Register the auth service
	authServer := NewAuthServer()
	authv3.RegisterAuthorizationServer(server, authServer)
	
	// Enable reflection for debugging
	reflection.Register(server)

	// Listen on the specified port
	lis, err := net.Listen("tcp", ":"+port)
	if err != nil {
		log.Fatalf("Failed to listen on port %s: %v", port, err)
	}

	log.Printf("ExtAuth service ready and listening on :%s", port)
	
	// Start serving
	if err := server.Serve(lis); err != nil {
		log.Fatalf("Failed to serve: %v", err)
	}
}