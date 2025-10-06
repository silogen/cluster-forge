package main

import (
	"context"
	"fmt"
	"log"
	"net"
	"net/url"
	"os"
	"strings"

	"github.com/coreos/go-oidc/v3/oidc"

	authv3 "github.com/envoyproxy/go-control-plane/envoy/service/auth/v3"
	corev3 "github.com/envoyproxy/go-control-plane/envoy/config/core/v3"
	typev3 "github.com/envoyproxy/go-control-plane/envoy/type/v3"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// CustomClaims defines the claims we want to extract
type CustomClaims struct {
	Email       string      `json:"email"`
	RealmAccess RealmAccess `json:"realm_access"`
}

type RealmAccess struct {
	Roles []string `json:"roles"`
}

type authServer struct {
	authv3.UnimplementedAuthorizationServer
	tokenVerifier *oidc.IDTokenVerifier
	keycloakAuth  string // full auth endpoint
	clientID      string
	workloadURL   string
}

// Check implements the ext_authz logic
func (a *authServer) Check(ctx context.Context, req *authv3.CheckRequest) (*authv3.CheckResponse, error) {
	headers := req.GetAttributes().GetRequest().GetHttp().GetHeaders()
	authHeader := headers["authorization"]

	path := req.GetAttributes().GetRequest().GetHttp().GetPath()
	log.Printf("[DEBUG1] Received request: method=%s path=%s headers=%d",
		req.GetAttributes().GetRequest().GetHttp().GetMethod(), path, len(headers))

	// 1. Check Authorization header first
	if authHeader == "" || !strings.HasPrefix(authHeader, "Bearer ") {
		log.Println("[DEBUG1] JWT cookie not found, redirecting to login")

		// Build redirect URL with client_id
		redirectURI := fmt.Sprintf("https://%s%s", a.workloadURL, path)
		loginURL := fmt.Sprintf("%s?client_id=%s&redirect_uri=%s&response_type=code&scope=openid+profile+email+organization",
			a.keycloakAuth, url.QueryEscape(a.clientID), url.QueryEscape(redirectURI))

		log.Printf("[DEBUG1] Redirecting user to loginURL=%s reason=Missing JWT", loginURL)

		// Return redirect response
		return &authv3.CheckResponse{
			Status: status.New(codes.PermissionDenied, "redirect to login").Proto(),
			HttpResponse: &authv3.CheckResponse_DeniedResponse{
				DeniedResponse: &authv3.DeniedHttpResponse{
					Status: &typev3.HttpStatus{Code: typev3.StatusCode_Found}, // 302 redirect
					Headers: []*corev3.HeaderValueOption{
						{
							Header: &corev3.HeaderValue{
								Key:   "Location",
								Value: loginURL,
							},
						},
					},
				},
			},
		}, nil
	}

	// 2. Extract token
	rawToken := strings.TrimPrefix(authHeader, "Bearer ")

	// 3. Verify the token
	idToken, err := a.tokenVerifier.Verify(ctx, rawToken)
	if err != nil {
		log.Printf("[INFO] Denied: Token verification failed: %v", err)
		return denyResponse(typev3.StatusCode_Unauthorized, fmt.Sprintf("Invalid token: %v", err)), nil
	}

	// 4. Extract claims
	var claims CustomClaims
	if err := idToken.Claims(&claims); err != nil {
		log.Printf("[ERROR] Failed to parse token claims: %v", err)
		return denyResponse(typev3.StatusCode_Forbidden, "Error parsing token claims"), nil
	}

	// 5. Require role "platform_administrator"
	if !hasRole(claims.RealmAccess.Roles, "platform_administrator") {
		log.Printf("[INFO] Denied: User '%s' missing required role 'platform_administrator'", claims.Email)
		return denyResponse(typev3.StatusCode_Forbidden, "Missing required role: Platform Administrator"), nil
	}

	// 6. Allow if checks pass
	log.Printf("[INFO] Allowed: User '%s' with roles %v", claims.Email, claims.RealmAccess.Roles)
	return allowResponse(claims.Email), nil
}

// hasRole helper
func hasRole(roles []string, requiredRole string) bool {
	for _, role := range roles {
		if role == requiredRole {
			return true
		}
	}
	return false
}

// denyResponse builds a Denied response
func denyResponse(statusCode typev3.StatusCode, body string, headers ...string) *authv3.CheckResponse {
	deniedResp := &authv3.DeniedHttpResponse{
		Status: &typev3.HttpStatus{Code: statusCode},
		Body:   body,
	}

	if len(headers) > 0 && len(headers)%2 == 0 {
		for i := 0; i < len(headers); i += 2 {
			deniedResp.Headers = append(deniedResp.Headers, &corev3.HeaderValueOption{
				Header: &corev3.HeaderValue{Key: headers[i], Value: headers[i+1]},
			})
		}
	}

	return &authv3.CheckResponse{
		Status:       status.New(codes.PermissionDenied, "request denied").Proto(),
		HttpResponse: &authv3.CheckResponse_DeniedResponse{DeniedResponse: deniedResp},
	}
}

// allowResponse builds an Allowed response
func allowResponse(userEmail string) *authv3.CheckResponse {
	return &authv3.CheckResponse{
		Status: status.New(codes.OK, "request allowed").Proto(),
		HttpResponse: &authv3.CheckResponse_OkResponse{
			OkResponse: &authv3.OkHttpResponse{
				Headers: []*corev3.HeaderValueOption{
					{
						Header: &corev3.HeaderValue{
							Key:   "x-auth-user-email",
							Value: userEmail,
						},
					},
				},
			},
		},
	}
}

func main() {
	// --- Config from env ---
	keycloakServerURL := getenv("KEYCLOAK_SERVER_URL", "http://localhost:8080")
	keycloakRealm := getenv("KEYCLOAK_REALM", "airm")
	keycloakClientID := getenv("KEYCLOAK_CLIENT_ID", "")
	listenAddr := getenv("LISTEN_ADDR", ":50051")
	workloadURL := getenv("WORKLOAD_URL", "workloads.app-dev.silogen.ai")

	// Build URLs
	keycloakAuth := fmt.Sprintf("%s/realms/%s/protocol/openid-connect/auth", keycloakServerURL, keycloakRealm)
	jwksURL := fmt.Sprintf("%s/realms/%s/protocol/openid-connect/certs", keycloakServerURL, keycloakRealm)

	log.Printf("Starting OpenID ExtAuth gRPC service on port %s", listenAddr)
	log.Printf("[DEBUG1] Configured AuthServer: loginURL=%s workloadURL=%s jwksURL=%s",
		keycloakAuth, workloadURL, jwksURL)

	ctx := context.Background()

	// Discover OIDC provider
	provider, err := oidc.NewProvider(ctx, fmt.Sprintf("%s/realms/%s", keycloakServerURL, keycloakRealm))
	if err != nil {
		log.Fatalf("Failed to create OIDC provider: %v", err)
	}

	// Build token verifier
	verifier := provider.Verifier(&oidc.Config{
		ClientID: keycloakClientID,
	})

	// Start gRPC ext_authz server
	lis, err := net.Listen("tcp", listenAddr)
	if err != nil {
		log.Fatalf("failed to listen: %v", err)
	}

	grpcServer := grpc.NewServer()
	authv3.RegisterAuthorizationServer(grpcServer, &authServer{
		tokenVerifier: verifier,
		keycloakAuth:  keycloakAuth,
		clientID:      keycloakClientID,
		workloadURL:   workloadURL,
	})

	if err := grpcServer.Serve(lis); err != nil {
		log.Fatalf("failed to serve: %v", err)
	}
}

func getenv(key, def string) string {
	if val, ok := os.LookupEnv(key); ok {
		return val
	}
	return def
}
