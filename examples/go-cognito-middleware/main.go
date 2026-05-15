package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"strings"
)

type contextKey string

const cognitoUserKey contextKey = "cognitoUser"

type CognitoUser struct {
	Subject     string                 `json:"sub,omitempty"`
	Email       string                 `json:"email,omitempty"`
	Username    string                 `json:"username,omitempty"`
	AccessToken string                 `json:"-"`
	Claims      map[string]interface{} `json:"claims,omitempty"`
}

func CognitoMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		user, err := userFromALBHeaders(r)
		if err != nil {
			http.Error(w, "missing Cognito identity headers", http.StatusUnauthorized)
			return
		}

		ctx := context.WithValue(r.Context(), cognitoUserKey, user)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

func userFromALBHeaders(r *http.Request) (*CognitoUser, error) {
	encodedJWT := r.Header.Get("x-amzn-oidc-data")
	if encodedJWT == "" {
		return nil, fmt.Errorf("missing x-amzn-oidc-data")
	}

	claims, err := decodeJWTPayload(encodedJWT)
	if err != nil {
		return nil, err
	}

	user := &CognitoUser{
		Subject:     stringClaim(claims, "sub"),
		Email:       stringClaim(claims, "email"),
		Username:    r.Header.Get("x-amzn-oidc-identity"),
		AccessToken: r.Header.Get("x-amzn-oidc-accesstoken"),
		Claims:      claims,
	}

	return user, nil
}

func decodeJWTPayload(token string) (map[string]interface{}, error) {
	parts := strings.Split(token, ".")
	if len(parts) < 2 {
		return nil, fmt.Errorf("invalid JWT format")
	}

	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return nil, err
	}

	var claims map[string]interface{}
	if err := json.Unmarshal(payload, &claims); err != nil {
		return nil, err
	}

	return claims, nil
}

func stringClaim(claims map[string]interface{}, key string) string {
	value, _ := claims[key].(string)
	return value
}

func UserFromContext(ctx context.Context) (*CognitoUser, bool) {
	user, ok := ctx.Value(cognitoUserKey).(*CognitoUser)
	return user, ok
}

func meHandler(w http.ResponseWriter, r *http.Request) {
	user, ok := UserFromContext(r.Context())
	if !ok {
		http.Error(w, "missing user", http.StatusUnauthorized)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(user)
}

func healthHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain")
	_, _ = w.Write([]byte("OK\n"))
}

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", healthHandler)
	mux.Handle("/me", CognitoMiddleware(http.HandlerFunc(meHandler)))
	mux.Handle("/", CognitoMiddleware(http.HandlerFunc(meHandler)))

	log.Println("listening on :8080")
	log.Fatal(http.ListenAndServe(":8080", mux))
}
