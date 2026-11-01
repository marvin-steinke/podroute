package webhook

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	kwhhttp "github.com/slok/kubewebhook/v2/pkg/http"
	kwhlog "github.com/slok/kubewebhook/v2/pkg/log"
	kwhmutating "github.com/slok/kubewebhook/v2/pkg/webhook/mutating"
	"net"
	"net/http"
	"podroute/internal/config"
	"podroute/internal/mutation"
	"time"
)

func Handler(profile config.Profile) (http.Handler, error) {
	mutator, err := mutation.New(profile)
	if err != nil {
		return nil, err
	}
	webhook, err := kwhmutating.NewWebhook(kwhmutating.WebhookConfig{ID: "podroute", Mutator: mutator, Logger: kwhlog.Noop})
	if err != nil {
		return nil, err
	}
	admission, err := kwhhttp.HandlerFor(kwhhttp.HandlerConfig{Webhook: webhook, Logger: kwhlog.Noop})
	if err != nil {
		return nil, err
	}
	mux := http.NewServeMux()
	mux.Handle("POST /mutate", http.MaxBytesHandler(admission, 1<<20))
	mux.HandleFunc("GET /healthz", func(writer http.ResponseWriter, _ *http.Request) {
		writer.WriteHeader(http.StatusOK)
		_, _ = writer.Write([]byte("ok\n"))
	})
	return mux, nil
}

func NewServer(address string, handler http.Handler, certificate, key string, insecure bool) (*http.Server, error) {
	server := &http.Server{Addr: address, Handler: handler, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 15 * time.Second, WriteTimeout: 15 * time.Second, IdleTimeout: 60 * time.Second, MaxHeaderBytes: 16 << 10}
	if insecure {
		host, _, err := net.SplitHostPort(address)
		if err != nil || (host != "localhost" && (net.ParseIP(host) == nil || !net.ParseIP(host).IsLoopback())) || certificate != "" || key != "" {
			return nil, fmt.Errorf("insecure mode requires a loopback listener and no TLS files")
		}
		return server, nil
	}
	if certificate == "" || key == "" {
		return nil, fmt.Errorf("both TLS certificate and key are required")
	}
	pair, err := tls.LoadX509KeyPair(certificate, key)
	if err != nil {
		return nil, fmt.Errorf("load TLS credentials: %w", err)
	}
	server.TLSConfig = &tls.Config{MinVersion: tls.VersionTLS12, Certificates: []tls.Certificate{pair}}
	return server, nil
}

func Run(ctx context.Context, server *http.Server) error {
	listener, err := net.Listen("tcp", server.Addr)
	if err != nil {
		return err
	}
	if server.TLSConfig != nil {
		listener = tls.NewListener(listener, server.TLSConfig)
	}
	result := make(chan error, 1)
	go func() { result <- server.Serve(listener) }()
	select {
	case err := <-result:
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return err
	case <-ctx.Done():
		shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := server.Shutdown(shutdown); err != nil {
			_ = server.Close()
			return fmt.Errorf("shutdown: %w", err)
		}
		err := <-result
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return err
	}
}
