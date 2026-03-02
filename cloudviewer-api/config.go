package main

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
)

type config struct {
	addr      string
	bucket    string
	prefix    string
	signTTL   time.Duration
	localRoot string
	keyFile   string
}

func loadConfig() (config, error) {
	cfg := config{
		addr:      envOrDefault("CLOUD_VIEWER_ADDR", ":8080"),
		bucket:    strings.TrimSpace(os.Getenv("GCS_BUCKET")),
		prefix:    normalizePrefix(os.Getenv("GCS_PREFIX")),
		signTTL:   15 * time.Minute,
		localRoot: envOrDefault("LOCAL_TESLACAM_PATH", "/TeslaCam"),
		keyFile:   strings.TrimSpace(os.Getenv("GOOGLE_APPLICATION_CREDENTIALS")),
	}

	if ttlRaw := strings.TrimSpace(os.Getenv("GCS_SIGN_TTL_SECONDS")); ttlRaw != "" {
		ttlSeconds, err := strconv.Atoi(ttlRaw)
		if err != nil || ttlSeconds <= 0 {
			return config{}, fmt.Errorf("invalid GCS_SIGN_TTL_SECONDS=%q", ttlRaw)
		}
		cfg.signTTL = time.Duration(ttlSeconds) * time.Second
	}

	return cfg, nil
}

func (cfg config) cloudEnabled() bool {
	return cfg.bucket != ""
}

func envOrDefault(key string, defaultVal string) string {
	val := strings.TrimSpace(os.Getenv(key))
	if val == "" {
		return defaultVal
	}
	return val
}
