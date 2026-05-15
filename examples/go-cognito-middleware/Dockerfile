FROM golang:1.22-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY main.go ./
RUN go build -o /out/server .

FROM alpine:3.20
COPY --from=build /out/server /server
EXPOSE 8080
ENTRYPOINT ["/server"]
