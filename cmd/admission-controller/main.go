package main

import (
	"context"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"podroute/internal/config"
	"podroute/internal/webhook"
	"syscall"
)

func run(ctx context.Context) error {
	filename := flag.String("config", "/etc/podroute/controller.json", "Controller profile JSON")
	address := flag.String("listen", ":8443", "Webhook listen address")
	certificate := flag.String("tls-cert", "", "TLS certificate PEM")
	key := flag.String("tls-key", "", "TLS private key PEM")
	insecure := flag.Bool("insecure-local", false, "Allow plaintext only on an explicit loopback listener")
	flag.Parse()
	file, err := os.Open(*filename)
	if err != nil {
		return err
	}
	defer file.Close()
	profile, err := config.Decode(file)
	if err != nil {
		return err
	}
	handler, err := webhook.Handler(profile)
	if err != nil {
		return err
	}
	server, err := webhook.NewServer(*address, handler, *certificate, *key, *insecure)
	if err != nil {
		return err
	}
	slog.Info("PodRoute controller listening", "address", *address, "tls", !*insecure)
	return webhook.Run(ctx, server)
}

func main() {
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stderr, nil)))
	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()
	if err := run(ctx); err != nil {
		slog.Error(fmt.Sprint(err))
		os.Exit(1)
	}
}
