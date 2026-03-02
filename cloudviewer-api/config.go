package main

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
)

type cloudProvider string

const (
	cloudProviderGCS cloudProvider = "gcs"
	cloudProviderS3  cloudProvider = "s3"
)

type gcsConfig struct {
	bucket  string
	prefix  string
	signTTL time.Duration
	keyFile string
}

type s3Config struct {
	bucket         string
	prefix         string
	signTTL        time.Duration
	region         string
	endpoint       string
	forcePathStyle bool
}

type config struct {
	addr            string
	localRoot       string
	defaultProvider cloudProvider
	gcs             *gcsConfig
	s3              *s3Config
}

func loadConfig() (config, error) {
	cfg := config{
		addr:            envOrDefault("CLOUD_VIEWER_ADDR", ":8080"),
		localRoot:       envOrDefault("LOCAL_TESLACAM_PATH", "/TeslaCam"),
		defaultProvider: cloudProviderGCS,
	}

	if providerRaw := strings.ToLower(strings.TrimSpace(os.Getenv("CLOUD_PROVIDER"))); providerRaw != "" {
		cfg.defaultProvider = cloudProvider(providerRaw)
	}
	if !isSupportedCloudProvider(cfg.defaultProvider) {
		return config{}, fmt.Errorf("invalid CLOUD_PROVIDER=%q", cfg.defaultProvider)
	}

	gcsBucket := strings.TrimSpace(os.Getenv("GCS_BUCKET"))
	if gcsBucket != "" {
		gcsTTL, err := durationFromEnvSecondsDefault("GCS_SIGN_TTL_SECONDS", 15*time.Minute)
		if err != nil {
			return config{}, err
		}
		gcsKeyFile := strings.TrimSpace(os.Getenv("GOOGLE_APPLICATION_CREDENTIALS"))
		if gcsKeyFile == "" {
			return config{}, fmt.Errorf("GOOGLE_APPLICATION_CREDENTIALS is required when GCS_BUCKET is set")
		}
		cfg.gcs = &gcsConfig{
			bucket:  gcsBucket,
			prefix:  normalizePrefix(os.Getenv("GCS_PREFIX")),
			signTTL: gcsTTL,
			keyFile: gcsKeyFile,
		}
	}

	s3Bucket := strings.TrimSpace(os.Getenv("S3_BUCKET"))
	if s3Bucket != "" {
		s3TTL, err := durationFromEnvSecondsDefault("S3_SIGN_TTL_SECONDS", 15*time.Minute)
		if err != nil {
			return config{}, err
		}
		s3Region := strings.TrimSpace(os.Getenv("S3_REGION"))
		if s3Region == "" {
			return config{}, fmt.Errorf("S3_REGION is required when S3_BUCKET is set")
		}

		s3ForcePathStyle := false
		forcePathStyleRaw := strings.TrimSpace(os.Getenv("S3_FORCE_PATH_STYLE"))
		if forcePathStyleRaw != "" {
			parsed, err := strconv.ParseBool(forcePathStyleRaw)
			if err != nil {
				return config{}, fmt.Errorf("invalid S3_FORCE_PATH_STYLE=%q", forcePathStyleRaw)
			}
			s3ForcePathStyle = parsed
		}

		cfg.s3 = &s3Config{
			bucket:         s3Bucket,
			prefix:         normalizePrefix(os.Getenv("S3_PREFIX")),
			signTTL:        s3TTL,
			region:         s3Region,
			endpoint:       strings.TrimSpace(os.Getenv("S3_ENDPOINT")),
			forcePathStyle: s3ForcePathStyle,
		}
	}

	return cfg, nil
}

func isSupportedCloudProvider(provider cloudProvider) bool {
	return provider == cloudProviderGCS || provider == cloudProviderS3
}

func (cfg config) cloudEnabled() bool {
	return cfg.gcs != nil || cfg.s3 != nil
}

func (cfg config) providerConfigured(provider cloudProvider) bool {
	switch provider {
	case cloudProviderGCS:
		return cfg.gcs != nil
	case cloudProviderS3:
		return cfg.s3 != nil
	default:
		return false
	}
}

func (cfg config) configuredProviders() []cloudProvider {
	providers := make([]cloudProvider, 0, 2)
	if cfg.gcs != nil {
		providers = append(providers, cloudProviderGCS)
	}
	if cfg.s3 != nil {
		providers = append(providers, cloudProviderS3)
	}
	return providers
}

func (cfg config) effectiveDefaultProvider() (cloudProvider, bool) {
	if cfg.providerConfigured(cfg.defaultProvider) {
		return cfg.defaultProvider, true
	}
	providers := cfg.configuredProviders()
	if len(providers) == 0 {
		return "", false
	}
	return providers[0], true
}

func (cfg config) providerBucket(provider cloudProvider) string {
	switch provider {
	case cloudProviderGCS:
		if cfg.gcs != nil {
			return cfg.gcs.bucket
		}
	case cloudProviderS3:
		if cfg.s3 != nil {
			return cfg.s3.bucket
		}
	}
	return ""
}

func (cfg config) providerPrefix(provider cloudProvider) string {
	switch provider {
	case cloudProviderGCS:
		if cfg.gcs != nil {
			return cfg.gcs.prefix
		}
	case cloudProviderS3:
		if cfg.s3 != nil {
			return cfg.s3.prefix
		}
	}
	return ""
}

func (cfg config) providerSignTTL(provider cloudProvider) time.Duration {
	switch provider {
	case cloudProviderGCS:
		if cfg.gcs != nil {
			return cfg.gcs.signTTL
		}
	case cloudProviderS3:
		if cfg.s3 != nil {
			return cfg.s3.signTTL
		}
	}
	return 15 * time.Minute
}

func (cfg config) resolveProvider(raw string) (cloudProvider, error) {
	if !cfg.cloudEnabled() {
		return "", fmt.Errorf("cloud viewer is not configured")
	}

	if trimmed := strings.ToLower(strings.TrimSpace(raw)); trimmed != "" {
		provider := cloudProvider(trimmed)
		if !isSupportedCloudProvider(provider) {
			return "", fmt.Errorf("invalid provider %q", raw)
		}
		if !cfg.providerConfigured(provider) {
			return "", fmt.Errorf("provider %q is not configured", provider)
		}
		return provider, nil
	}

	provider, ok := cfg.effectiveDefaultProvider()
	if !ok {
		return "", fmt.Errorf("cloud viewer is not configured")
	}
	return provider, nil
}

func cloudProviderLabel(provider cloudProvider) string {
	switch provider {
	case cloudProviderGCS:
		return "GCS"
	case cloudProviderS3:
		return "S3"
	default:
		return strings.ToUpper(string(provider))
	}
}

func durationFromEnvSecondsDefault(key string, defaultVal time.Duration) (time.Duration, error) {
	raw := strings.TrimSpace(os.Getenv(key))
	if raw == "" {
		return defaultVal, nil
	}
	seconds, err := strconv.Atoi(raw)
	if err != nil || seconds <= 0 {
		return 0, fmt.Errorf("invalid %s=%q", key, raw)
	}
	return time.Duration(seconds) * time.Second, nil
}

func envOrDefault(key string, defaultVal string) string {
	val := strings.TrimSpace(os.Getenv(key))
	if val == "" {
		return defaultVal
	}
	return val
}
