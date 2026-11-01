FROM --platform=$BUILDPLATFORM docker.io/library/golang:1.27.3-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY cmd ./cmd
COPY internal ./internal
ARG TARGETOS=linux
ARG TARGETARCH
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -trimpath -ldflags='-s -w' -o /controller ./cmd/admission-controller

FROM scratch
COPY --from=build /controller /controller
COPY LICENSE NOTICE /
USER 65532:65532
EXPOSE 8443
ENTRYPOINT ["/controller"]