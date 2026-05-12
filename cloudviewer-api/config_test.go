package main

import (
	"testing"
	"time"
)

func TestLoadConfigDefaults(t *testing.T) {
	clearCloudViewerEnv(t)

	cfg, err := loadConfig()
	if err != nil {
		t.Fatalf("loadConfig: %v", err)
	}

	if cfg.defaultProvider != cloudProviderGCS {
		t.Fatalf("defaultProvider=%q want=%q", cfg.defaultProvider, cloudProviderGCS)
	}
	if cfg.cloudEnabled() {
		t.Fatalf("cloudEnabled=true want=false")
	}
}

func TestLoadConfigRejectsInvalidProvider(t *testing.T) {
	clearCloudViewerEnv(t)
	t.Setenv("CLOUD_PROVIDER", "blob")

	if _, err := loadConfig(); err == nil {
		t.Fatalf("loadConfig expected error")
	}
}

func TestLoadConfigGCSRequiresKeyWhenBucketSet(t *testing.T) {
	clearCloudViewerEnv(t)
	t.Setenv("GCS_BUCKET", "teslacam")
	t.Setenv("GOOGLE_APPLICATION_CREDENTIALS", "")

	if _, err := loadConfig(); err == nil {
		t.Fatalf("loadConfig expected error for missing GOOGLE_APPLICATION_CREDENTIALS")
	}
}

func TestLoadConfigS3(t *testing.T) {
	clearCloudViewerEnv(t)
	t.Setenv("CLOUD_PROVIDER", "s3")
	t.Setenv("S3_BUCKET", "teslacam-archive")
	t.Setenv("S3_PREFIX", "TeslaCam")
	t.Setenv("S3_REGION", "us-east-1")
	t.Setenv("S3_ENDPOINT", "https://s3.us-east-1.amazonaws.com")
	t.Setenv("S3_FORCE_PATH_STYLE", "true")
	t.Setenv("S3_SIGN_TTL_SECONDS", "1200")

	cfg, err := loadConfig()
	if err != nil {
		t.Fatalf("loadConfig: %v", err)
	}
	if cfg.s3 == nil {
		t.Fatalf("s3 config missing")
	}
	if cfg.s3.bucket != "teslacam-archive" {
		t.Fatalf("bucket=%q", cfg.s3.bucket)
	}
	if cfg.s3.prefix != "TeslaCam/" {
		t.Fatalf("prefix=%q want=%q", cfg.s3.prefix, "TeslaCam/")
	}
	if cfg.s3.region != "us-east-1" {
		t.Fatalf("region=%q", cfg.s3.region)
	}
	if !cfg.s3.forcePathStyle {
		t.Fatalf("forcePathStyle=false want=true")
	}
	if cfg.s3.signTTL != 1200*time.Second {
		t.Fatalf("signTTL=%v want=%v", cfg.s3.signTTL, 1200*time.Second)
	}
}

func TestLoadConfigBothProviders(t *testing.T) {
	clearCloudViewerEnv(t)
	t.Setenv("CLOUD_PROVIDER", "s3")
	t.Setenv("GCS_BUCKET", "gcs-bucket")
	t.Setenv("GCS_PREFIX", "TeslaCam")
	t.Setenv("GOOGLE_APPLICATION_CREDENTIALS", "/tmp/key.json")
	t.Setenv("S3_BUCKET", "s3-bucket")
	t.Setenv("S3_REGION", "us-east-1")

	cfg, err := loadConfig()
	if err != nil {
		t.Fatalf("loadConfig: %v", err)
	}
	if !cfg.cloudEnabled() {
		t.Fatalf("cloudEnabled=false want=true")
	}
	if cfg.gcs == nil || cfg.s3 == nil {
		t.Fatalf("expected both providers configured")
	}

	providers := cfg.configuredProviders()
	if len(providers) != 2 {
		t.Fatalf("configuredProviders=%v", providers)
	}

	defaultProvider, ok := cfg.effectiveDefaultProvider()
	if !ok || defaultProvider != cloudProviderS3 {
		t.Fatalf("effectiveDefaultProvider=%q ok=%t want=%q", defaultProvider, ok, cloudProviderS3)
	}
}

func TestResolveProvider(t *testing.T) {
	clearCloudViewerEnv(t)
	t.Setenv("GCS_BUCKET", "gcs-bucket")
	t.Setenv("GOOGLE_APPLICATION_CREDENTIALS", "/tmp/key.json")
	t.Setenv("S3_BUCKET", "s3-bucket")
	t.Setenv("S3_REGION", "us-east-1")

	cfg, err := loadConfig()
	if err != nil {
		t.Fatalf("loadConfig: %v", err)
	}

	provider, err := cfg.resolveProvider("")
	if err != nil || provider != cloudProviderGCS {
		t.Fatalf("resolveProvider default provider=%q err=%v", provider, err)
	}

	provider, err = cfg.resolveProvider("s3")
	if err != nil || provider != cloudProviderS3 {
		t.Fatalf("resolveProvider s3 provider=%q err=%v", provider, err)
	}

	if _, err := cfg.resolveProvider("azure"); err == nil {
		t.Fatalf("resolveProvider expected invalid provider error")
	}
}

func TestLoadConfigS3RequiresRegionWhenBucketSet(t *testing.T) {
	clearCloudViewerEnv(t)
	t.Setenv("S3_BUCKET", "teslacam-archive")

	if _, err := loadConfig(); err == nil {
		t.Fatalf("loadConfig expected error for missing S3_REGION")
	}
}

func clearCloudViewerEnv(t *testing.T) {
	t.Helper()

	keys := []string{
		"CLOUD_PROVIDER",
		"CLOUD_VIEWER_ADDR",
		"LOCAL_TESLACAM_PATH",
		"GCS_BUCKET",
		"GCS_PREFIX",
		"GCS_SIGN_TTL_SECONDS",
		"GOOGLE_APPLICATION_CREDENTIALS",
		"S3_BUCKET",
		"S3_PREFIX",
		"S3_REGION",
		"S3_ENDPOINT",
		"S3_FORCE_PATH_STYLE",
		"S3_SIGN_TTL_SECONDS",
	}
	for _, key := range keys {
		t.Setenv(key, "")
	}
}
