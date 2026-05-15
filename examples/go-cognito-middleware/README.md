# Go Cognito Middleware Example

This example reads Cognito identity headers injected by an AWS ALB Ingress with Cognito authentication enabled.

The middleware intentionally does not verify the JWT signature because the ALB is expected to handle authentication before forwarding traffic.

Relevant ALB headers:

- `x-amzn-oidc-data`: JWT containing user claims
- `x-amzn-oidc-identity`: Cognito subject/user identity
- `x-amzn-oidc-accesstoken`: Cognito access token

Run locally:

```bash
go run .
```

Health check:

```bash
curl http://localhost:8080/healthz
```

Authenticated route simulation:

```bash
HEADER_PAYLOAD="$(printf '{"sub":"123","email":"dev@example.com"}' | base64 | tr '+/' '-_' | tr -d '=')"
curl \
  -H "x-amzn-oidc-data: header.${HEADER_PAYLOAD}.signature" \
  -H "x-amzn-oidc-identity: 123" \
  -H "x-amzn-oidc-accesstoken: test-token" \
  http://localhost:8080/me
```
