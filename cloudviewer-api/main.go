package main

import (
	"context"
	"log"
	"net/http"
)

func main() {
	cfg, err := loadConfig()
	if err != nil {
		log.Fatalf("load config: %v", err)
	}

	app, err := newApp(context.Background(), cfg)
	if err != nil {
		log.Fatalf("init app: %v", err)
	}
	defer func() {
		if err := app.close(); err != nil {
			log.Printf("close app: %v", err)
		}
	}()

	log.Printf("cloudviewer-api listening on %s", cfg.addr)
	log.Printf("cloud enabled=%t default_provider=%q providers=%v local_root=%q",
		cfg.cloudEnabled(),
		cfg.defaultProvider,
		cfg.configuredProviders(),
		cfg.localRoot,
	)

	if err := http.ListenAndServe(cfg.addr, app.routes()); err != nil {
		log.Fatalf("serve: %v", err)
	}
}
