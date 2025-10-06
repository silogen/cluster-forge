package main

import (
	"context"
	"fmt"
	"log"
	"net"
	"os"
	"strings"

	authv3 "github.com/envoyproxy/go-control-plane/envoy/service/auth/v3"
	corev3 "github.com/envoyproxy/go-control-plane/envoy/config/core/v3"
	typev3 "github.com/envoyproxy/go-control-plane/envoy/type/v3"
	rpcstatus "google.golang.org/genproto/googleapis/rpc/status"
	"google.golang.org/grpc"
)

type authServer struct {
	authv3.UnimplementedAuthorizationServer
	sessionCookie string
	redirectURL   string
}

// Check implements the ext_authz check logic
func (a *authServer) Check(ctx context.Context, req *authv3.CheckRequest) (*authv3.CheckResponse, error) {
	headers := req.GetAttributes().GetRequest().GetHttp().GetHeaders()
	cookieHeader := headers["cookie"]
	path := req.GetAttributes().GetRequest().GetHttp().GetPath()

	log.Printf("[DEBUG] Incoming request: path=%s", path)
	log.Printf("[DEBUG] Cookie header: %s", cookieHeader)
	log.Printf("[DEBUG] All headers: %+v", headers)

	hasCookies := hasRequiredCookies(cookieHeader, a.sessionCookie)
	isTopLevel := isTopLevelNavigation(headers)

	// If cookies are missing
	if !hasCookies {
		if isTopLevel {
			// Redirect top-level navigation
			log.Printf("[INFO] Redirected: missing cookies for top-level navigation, redirecting to %s", a.redirectURL)
			return &authv3.CheckResponse{
				Status: &rpcstatus.Status{Code: int32(0)}, // OK
				HttpResponse: &authv3.CheckResponse_DeniedResponse{
					DeniedResponse: &authv3.DeniedHttpResponse{
						Status: &typev3.HttpStatus{Code: typev3.StatusCode_TemporaryRedirect},
						Headers: []*corev3.HeaderValueOption{
							{
								Header: &corev3.HeaderValue{
									Key:   "Location",
									Value: a.redirectURL,
								},
							},
						},
						Body: fmt.Sprintf("Redirecting to %s", a.redirectURL),
					},
				},
			}, nil
		} else {
			// Block all other requests
			log.Printf("[INFO] Blocked: missing cookies for subresource request")
			return &authv3.CheckResponse{
				Status: &rpcstatus.Status{Code: int32(0)},
				HttpResponse: &authv3.CheckResponse_DeniedResponse{
					DeniedResponse: &authv3.DeniedHttpResponse{
						Status: &typev3.HttpStatus{Code: typev3.StatusCode_Forbidden},
						Body:   "Forbidden: missing session cookies",
					},
				},
			}, nil
		}
	}

	// Cookies present → allow request
	log.Printf("[INFO] Allowed: required cookies present")
	return &authv3.CheckResponse{
		Status: &rpcstatus.Status{Code: int32(0)},
		HttpResponse: &authv3.CheckResponse_OkResponse{
			OkResponse: &authv3.OkHttpResponse{
				Headers: []*corev3.HeaderValueOption{
					{
						Header: &corev3.HeaderValue{
							Key:   "x-ext-authz",
							Value: "allowed",
						},
					},
				},
			},
		},
	}, nil
}

// hasRequiredCookies checks for both the session cookie and _xsrf in the header
func hasRequiredCookies(cookieHeader, sessionCookie string) bool {
	if cookieHeader == "" {
		return false
	}
	cookies := strings.Split(cookieHeader, ";")
	hasSession := false
	hasXsrf := false

	for _, c := range cookies {
		c = strings.TrimSpace(c)
		if strings.HasPrefix(c, sessionCookie+"=") {
			hasSession = true
		}
		if strings.HasPrefix(c, "_xsrf=") {
			hasXsrf = true
		}
	}

	return hasSession && hasXsrf
}

// isTopLevelNavigation determines if the request is a top-level HTML navigation
func isTopLevelNavigation(headers map[string]string) bool {
	accept := headers["accept"]
	secFetchDest := headers["sec-fetch-dest"]
	secFetchMode := headers["sec-fetch-mode"]

	// Basic check: top-level HTML navigation typically has Accept: text/html and sec-fetch-dest: document
	return strings.Contains(accept, "text/html") &&
		(secFetchDest == "document" || secFetchDest == "") &&
		(secFetchMode == "navigate" || secFetchMode == "")
}

func main() {
	sessionCookie := getenv("SESSION_COOKIE_NAME", "username-workspaces-app-dev-silogen-ai")
	redirectURL := getenv("REDIRECT_URL", "https://airmui.app-dev.silogen.ai/api/auth/signin?callbackUrl=%2F")
	listenAddr := getenv("LISTEN_ADDR", ":50051")

	if !strings.Contains(listenAddr, ":") {
		listenAddr = ":" + listenAddr
	}

	log.Printf("Starting gRPC ExtAuth server on %s", listenAddr)
	log.Printf("Config: SESSION_COOKIE_NAME=%s, REDIRECT_URL=%s", sessionCookie, redirectURL)

	lis, err := net.Listen("tcp", listenAddr)
	if err != nil {
		log.Fatalf("failed to listen: %v", err)
	}

	grpcServer := grpc.NewServer()
	authv3.RegisterAuthorizationServer(grpcServer, &authServer{
		sessionCookie: sessionCookie,
		redirectURL:   redirectURL,
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
