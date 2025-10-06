package main

import (
	"context"
	"io"
	"log"
	"net"
	"net/http"
	"os"

	authv3 "github.com/envoyproxy/go-control-plane/envoy/service/auth/v3"
	corev3 "github.com/envoyproxy/go-control-plane/envoy/config/core/v3"
	typev3 "github.com/envoyproxy/go-control-plane/envoy/type/v3"
	statusv1 "google.golang.org/genproto/googleapis/rpc/status"
	"google.golang.org/grpc"
	codes "google.golang.org/grpc/codes"
)

// authServer implements Envoy ext_authz
type authServer struct {
	authv3.UnimplementedAuthorizationServer
	oauth2ProxyURL string
}

func (s *authServer) Check(ctx context.Context, req *authv3.CheckRequest) (*authv3.CheckResponse, error) {
	// Call oauth2-proxy /auth endpoint
	httpReq, _ := http.NewRequest("GET", s.oauth2ProxyURL+"/auth", nil)
	for k, v := range req.GetAttributes().GetRequest().GetHttp().GetHeaders() {
		httpReq.Header.Set(k, v)
	}

	resp, err := http.DefaultClient.Do(httpReq)
	if err != nil {
		log.Printf("error calling oauth2-proxy: %v", err)
		return denyResponse("authz_error"), nil
	}
	defer resp.Body.Close()
	io.Copy(io.Discard, resp.Body)

	// oauth2-proxy returns 202 if authenticated, 401 if not
	if resp.StatusCode == 202 {
		log.Println("Request authorized by oauth2-proxy")
		return okResponse(), nil
	}

	// Not authorized → redirect to login page
	loginURL := os.Getenv("LOGIN_URL")
	if loginURL == "" {
		loginURL = "https://example.com/login"
	}
	log.Printf("Not authenticated, redirecting to %s", loginURL)
	return redirectResponse(loginURL), nil
}

func okResponse() *authv3.CheckResponse {
	return &authv3.CheckResponse{
		Status: &statusv1.Status{Code: int32(codes.OK)},
		HttpResponse: &authv3.CheckResponse_OkResponse{
			OkResponse: &authv3.OkHttpResponse{
				Headers: []*corev3.HeaderValueOption{
					{Header: &corev3.HeaderValue{Key: "x-authz", Value: "allowed"}},
				},
			},
		},
	}
}

func denyResponse(reason string) *authv3.CheckResponse {
	return &authv3.CheckResponse{
		Status: &statusv1.Status{Code: int32(codes.Unauthenticated)},
		HttpResponse: &authv3.CheckResponse_DeniedResponse{
			DeniedResponse: &authv3.DeniedHttpResponse{
				// Status: nil, // <- TODO: I need use this code from authv3.StatusCode_Unauthorized
				Status: &typev3.HttpStatus{
					Code: typev3.StatusCode_Unauthorized,
				}, 
				Body:   reason,
			},
		},
	}
}

func redirectResponse(location string) *authv3.CheckResponse {
	return &authv3.CheckResponse{
		Status: &statusv1.Status{Code: int32(codes.Unauthenticated)},
		HttpResponse: &authv3.CheckResponse_DeniedResponse{
			DeniedResponse: &authv3.DeniedHttpResponse{
				// Status: nil, // <- TODO: I need use this code from authv3.StatusCode_Found
				Status: &typev3.HttpStatus{ // <--- CHANGED
					Code: typev3.StatusCode_Found, // <--- CHANGED: Sets HTTP status 302
				}, 
				Headers: []*corev3.HeaderValueOption{
					{Header: &corev3.HeaderValue{Key: "Location", Value: location}},
				},
			},
		},
	}
}

func main() {
	oauth2ProxyURL := os.Getenv("OAUTH2_PROXY_URL")
	if oauth2ProxyURL == "" {
		oauth2ProxyURL = "http://localhost:4180"
	}

	lis, err := net.Listen("tcp", ":50051")
	if err != nil {
		log.Fatalf("failed to listen: %v", err)
	}

	s := grpc.NewServer()
	authv3.RegisterAuthorizationServer(s, &authServer{oauth2ProxyURL: oauth2ProxyURL})

	log.Println("Starting gRPC ext_authz adapter on :50051")
	if err := s.Serve(lis); err != nil {
		log.Fatalf("failed to serve: %v", err)
	}
}
