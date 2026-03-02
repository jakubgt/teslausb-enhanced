package main

import (
	"cloud.google.com/go/storage"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	awsv2 "github.com/aws/aws-sdk-go-v2/aws"
	awscfg "github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"io"
	"io/fs"
	"math"
	"net/http"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"time"

	"google.golang.org/api/iterator"
)

type app struct {
	cfg             config
	gcsStorage      *storage.Client
	gcsSignerEmail  string
	gcsSignerKey    []byte
	s3Client        *s3.Client
	s3PresignClient *s3.PresignClient
	httpClient      *http.Client
}

type serviceAccountKey struct {
	ClientEmail string `json:"client_email"`
	PrivateKey  string `json:"private_key"`
}

type cloudProviderHealth struct {
	provider cloudProvider
	label    string
	bucket   string
	prefix   string
	healthy  bool
	err      string
}

func newApp(ctx context.Context, cfg config) (*app, error) {
	result := &app{
		cfg: cfg,
		httpClient: &http.Client{
			Timeout: 30 * time.Second,
		},
	}

	if cfg.gcs != nil {
		if err := result.initGCS(ctx, cfg.gcs); err != nil {
			return nil, err
		}
	}
	if cfg.s3 != nil {
		if err := result.initS3(ctx, cfg.s3); err != nil {
			return nil, err
		}
	}

	return result, nil
}

func (a *app) initGCS(ctx context.Context, gcsCfg *gcsConfig) error {
	storageClient, err := storage.NewClient(ctx)
	if err != nil {
		return fmt.Errorf("create gcs client: %w", err)
	}
	a.gcsStorage = storageClient

	keyBytes, err := os.ReadFile(gcsCfg.keyFile)
	if err != nil {
		return fmt.Errorf("read service-account key: %w", err)
	}
	var key serviceAccountKey
	if err := json.Unmarshal(keyBytes, &key); err != nil {
		return fmt.Errorf("parse service-account key: %w", err)
	}
	if strings.TrimSpace(key.ClientEmail) == "" || strings.TrimSpace(key.PrivateKey) == "" {
		return fmt.Errorf("service-account key missing client_email/private_key")
	}
	a.gcsSignerEmail = key.ClientEmail
	a.gcsSignerKey = []byte(key.PrivateKey)
	return nil
}

func (a *app) initS3(ctx context.Context, s3Cfg *s3Config) error {
	awsConfig, err := awscfg.LoadDefaultConfig(ctx, awscfg.WithRegion(s3Cfg.region))
	if err != nil {
		return fmt.Errorf("load aws config: %w", err)
	}
	a.s3Client = s3.NewFromConfig(awsConfig, func(options *s3.Options) {
		options.UsePathStyle = s3Cfg.forcePathStyle
		if s3Cfg.endpoint != "" {
			options.BaseEndpoint = awsv2.String(s3Cfg.endpoint)
		}
	})
	a.s3PresignClient = s3.NewPresignClient(a.s3Client)
	return nil
}

func (a *app) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/api/v1/cloud/health", a.handleCloudHealth)
	mux.HandleFunc("/api/v1/cloud/videolist", a.handleCloudVideoList)
	mux.HandleFunc("/api/v1/cloud/object-url", a.handleCloudObjectURL)
	mux.HandleFunc("/api/v1/cloud/stream", a.handleCloudStream)
	mux.HandleFunc("/api/v1/local/config", a.handleLocalConfig)
	mux.HandleFunc("/api/v1/local/status", a.handleLocalStatus)
	mux.HandleFunc("/api/v1/local/videolist", a.handleLocalVideoList)
	return mux
}

func (a *app) close() error {
	if a.gcsStorage != nil {
		return a.gcsStorage.Close()
	}
	return nil
}

func (a *app) handleCloudHealth(w http.ResponseWriter, r *http.Request) {
	resp := map[string]any{
		"enabled": a.cfg.cloudEnabled(),
	}
	if !a.cfg.cloudEnabled() {
		writeJSON(w, http.StatusOK, resp)
		return
	}

	configuredProviders := a.cfg.configuredProviders()
	configuredProviderNames := make([]string, 0, len(configuredProviders))
	healthyProviderNames := make([]string, 0, len(configuredProviders))
	providerPayload := make(map[string]any, len(configuredProviders))
	statusByProvider := make(map[cloudProvider]cloudProviderHealth, len(configuredProviders))

	for _, provider := range configuredProviders {
		status := a.cloudProviderStatus(context.Background(), provider)
		statusByProvider[provider] = status
		configuredProviderNames = append(configuredProviderNames, string(provider))
		if status.healthy {
			healthyProviderNames = append(healthyProviderNames, string(provider))
		}

		payload := map[string]any{
			"configured": true,
			"label":      status.label,
			"bucket":     status.bucket,
			"prefix":     status.prefix,
			"healthy":    status.healthy,
		}
		if status.err != "" {
			payload["error"] = status.err
		}
		providerPayload[string(provider)] = payload
	}

	resp["configured_providers"] = configuredProviderNames
	resp["healthy_providers"] = healthyProviderNames
	resp["providers"] = providerPayload

	defaultProvider, hasDefault := a.cfg.effectiveDefaultProvider()
	if hasDefault {
		resp["default_provider"] = string(defaultProvider)
	}

	summaryProvider, hasSummaryProvider, err := a.summaryProviderFromRequest(r)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_provider", err.Error())
		return
	}
	if hasSummaryProvider {
		status, ok := statusByProvider[summaryProvider]
		if ok {
			resp["provider"] = string(status.provider)
			resp["label"] = status.label
			resp["bucket"] = status.bucket
			resp["prefix"] = status.prefix
			resp["healthy"] = status.healthy
			if status.err != "" {
				resp["error"] = status.err
			}
		}
	}

	writeJSON(w, http.StatusOK, resp)
}

func (a *app) summaryProviderFromRequest(r *http.Request) (cloudProvider, bool, error) {
	rawProvider := strings.TrimSpace(r.URL.Query().Get("provider"))
	if rawProvider != "" {
		provider, err := a.cfg.resolveProvider(rawProvider)
		if err != nil {
			return "", false, err
		}
		return provider, true, nil
	}
	provider, ok := a.cfg.effectiveDefaultProvider()
	return provider, ok, nil
}

func (a *app) cloudProviderFromRequest(r *http.Request) (cloudProvider, error) {
	return a.cfg.resolveProvider(r.URL.Query().Get("provider"))
}

func (a *app) cloudProviderStatus(parentCtx context.Context, provider cloudProvider) cloudProviderHealth {
	status := cloudProviderHealth{
		provider: provider,
		label:    cloudProviderLabel(provider),
		bucket:   a.cfg.providerBucket(provider),
		prefix:   strings.TrimSuffix(a.cfg.providerPrefix(provider), "/"),
	}

	ctx, cancel := context.WithTimeout(parentCtx, 5*time.Second)
	defer cancel()
	if err := a.cloudHealth(ctx, provider); err != nil {
		status.healthy = false
		status.err = err.Error()
		return status
	}
	status.healthy = true
	return status
}

func (a *app) handleCloudVideoList(w http.ResponseWriter, r *http.Request) {
	if !a.cfg.cloudEnabled() {
		writeError(w, http.StatusNotFound, "cloud_disabled", "cloud viewer is not configured")
		return
	}

	provider, err := a.cloudProviderFromRequest(r)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_provider", err.Error())
		return
	}

	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	lines, err := a.listCloudMedia(ctx, provider)
	if err != nil {
		writeError(w, http.StatusBadGateway, "cloud_list_failed", err.Error())
		return
	}
	writeTextLines(w, lines)
}

func (a *app) cloudHealth(ctx context.Context, provider cloudProvider) error {
	switch provider {
	case cloudProviderGCS:
		if a.cfg.gcs == nil || a.gcsStorage == nil {
			return fmt.Errorf("provider %q is not configured", provider)
		}
		it := a.gcsStorage.Bucket(a.cfg.gcs.bucket).Objects(ctx, &storage.Query{Prefix: a.cfg.gcs.prefix})
		if _, err := it.Next(); err != nil && !errors.Is(err, iterator.Done) {
			return err
		}
		return nil

	case cloudProviderS3:
		if a.cfg.s3 == nil || a.s3Client == nil {
			return fmt.Errorf("provider %q is not configured", provider)
		}
		_, err := a.s3Client.ListObjectsV2(ctx, &s3.ListObjectsV2Input{
			Bucket:  awsv2.String(a.cfg.s3.bucket),
			Prefix:  awsv2.String(a.cfg.s3.prefix),
			MaxKeys: awsv2.Int32(1),
		})
		return err

	default:
		return fmt.Errorf("unsupported cloud provider %q", provider)
	}
}

func (a *app) listCloudMedia(ctx context.Context, provider cloudProvider) ([]string, error) {
	switch provider {
	case cloudProviderGCS:
		return a.listGCSMedia(ctx)
	case cloudProviderS3:
		return a.listS3Media(ctx)
	default:
		return nil, fmt.Errorf("unsupported cloud provider %q", provider)
	}
}

func (a *app) listGCSMedia(ctx context.Context) ([]string, error) {
	if a.cfg.gcs == nil || a.gcsStorage == nil {
		return nil, fmt.Errorf("provider %q is not configured", cloudProviderGCS)
	}

	it := a.gcsStorage.Bucket(a.cfg.gcs.bucket).Objects(ctx, &storage.Query{Prefix: a.cfg.gcs.prefix})
	lines := make([]string, 0, 4096)
	for {
		attrs, err := it.Next()
		if errors.Is(err, iterator.Done) {
			break
		}
		if err != nil {
			return nil, err
		}
		if attrs == nil {
			continue
		}
		if rel, ok := relativeFromObjectName(a.cfg.gcs.prefix, attrs.Name); ok {
			lines = append(lines, rel)
		}
	}
	return sortedUniqueLines(lines), nil
}

func (a *app) listS3Media(ctx context.Context) ([]string, error) {
	if a.cfg.s3 == nil || a.s3Client == nil {
		return nil, fmt.Errorf("provider %q is not configured", cloudProviderS3)
	}

	paginator := s3.NewListObjectsV2Paginator(a.s3Client, &s3.ListObjectsV2Input{
		Bucket: awsv2.String(a.cfg.s3.bucket),
		Prefix: awsv2.String(a.cfg.s3.prefix),
	})
	lines := make([]string, 0, 4096)

	for paginator.HasMorePages() {
		page, err := paginator.NextPage(ctx)
		if err != nil {
			return nil, err
		}
		for _, object := range page.Contents {
			if object.Key == nil {
				continue
			}
			if rel, ok := relativeFromObjectName(a.cfg.s3.prefix, awsv2.ToString(object.Key)); ok {
				lines = append(lines, rel)
			}
		}
	}
	return sortedUniqueLines(lines), nil
}

func (a *app) handleLocalVideoList(w http.ResponseWriter, _ *http.Request) {
	lines, err := buildLocalVideoList(a.cfg.localRoot)
	if err != nil {
		writeError(w, http.StatusBadGateway, "local_list_failed", err.Error())
		return
	}
	writeTextLines(w, lines)
}

func (a *app) handleLocalConfig(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{
		"has_music":     "no",
		"has_lightshow": "no",
		"has_boombox":   "no",
		"has_cam":       "yes",
		"uses_ble":      "no",
	})
}

func (a *app) handleLocalStatus(w http.ResponseWriter, _ *http.Request) {
	totalSpace := int64(0)
	freeSpace := int64(0)
	var stat syscall.Statfs_t
	if err := syscall.Statfs(a.cfg.localRoot, &stat); err == nil {
		totalSpace = int64(math.Round(float64(stat.Blocks) * float64(stat.Bsize)))
		freeSpace = int64(math.Round(float64(stat.Bavail) * float64(stat.Bsize)))
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"cpu_temp":        "",
		"num_snapshots":   "0",
		"snapshot_oldest": "",
		"snapshot_newest": "",
		"total_space":     fmt.Sprintf("%d", totalSpace),
		"free_space":      fmt.Sprintf("%d", freeSpace),
		"uptime":          "0",
		"drives_active":   "yes",
		"wifi_ssid":       "",
		"wifi_freq":       "",
		"wifi_strength":   "",
		"wifi_ip":         "",
		"ether_ip":        "",
		"ether_speed":     "",
	})
}

func buildLocalVideoList(localRoot string) ([]string, error) {
	lines := make([]string, 0, 2048)
	err := filepath.WalkDir(localRoot, func(current string, d fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if d.IsDir() {
			return nil
		}
		rel, err := filepath.Rel(localRoot, current)
		if err != nil {
			return err
		}
		rel = filepath.ToSlash(rel)
		if rel == "." || strings.HasPrefix(rel, "../") {
			return nil
		}
		if _, err := normalizeRelativePath(rel); err != nil {
			return nil
		}
		if !isSupportedMediaExt(rel) {
			return nil
		}
		lines = append(lines, rel)
		return nil
	})
	if err != nil {
		return nil, err
	}
	sort.Strings(lines)
	return lines, nil
}

func (a *app) handleCloudObjectURL(w http.ResponseWriter, r *http.Request) {
	if !a.cfg.cloudEnabled() {
		writeError(w, http.StatusNotFound, "cloud_disabled", "cloud viewer is not configured")
		return
	}

	provider, err := a.cloudProviderFromRequest(r)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_provider", err.Error())
		return
	}

	relPath, err := normalizeRelativePath(r.URL.Query().Get("path"))
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_path", err.Error())
		return
	}

	download := r.URL.Query().Get("download") == "1"
	signedURL, expiresAt, err := a.signObjectURL(provider, relPath, download)
	if err != nil {
		writeError(w, http.StatusBadGateway, "sign_failed", err.Error())
		return
	}

	writeJSON(w, http.StatusOK, map[string]string{
		"url":        signedURL,
		"expires_at": expiresAt.UTC().Format(time.RFC3339),
	})
}

func (a *app) handleCloudStream(w http.ResponseWriter, r *http.Request) {
	if !a.cfg.cloudEnabled() {
		writeError(w, http.StatusNotFound, "cloud_disabled", "cloud viewer is not configured")
		return
	}

	provider, err := a.cloudProviderFromRequest(r)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_provider", err.Error())
		return
	}

	relPath, err := normalizeRelativePath(r.URL.Query().Get("path"))
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_path", err.Error())
		return
	}
	download := r.URL.Query().Get("download") == "1"
	signedURL, _, err := a.signObjectURL(provider, relPath, download)
	if err != nil {
		writeError(w, http.StatusBadGateway, "sign_failed", err.Error())
		return
	}

	req, err := http.NewRequestWithContext(r.Context(), http.MethodGet, signedURL, nil)
	if err != nil {
		writeError(w, http.StatusBadGateway, "proxy_failed", err.Error())
		return
	}
	if v := r.Header.Get("Range"); v != "" {
		req.Header.Set("Range", v)
	}
	if v := r.Header.Get("If-Range"); v != "" {
		req.Header.Set("If-Range", v)
	}
	if v := r.Header.Get("If-None-Match"); v != "" {
		req.Header.Set("If-None-Match", v)
	}
	if v := r.Header.Get("If-Modified-Since"); v != "" {
		req.Header.Set("If-Modified-Since", v)
	}

	resp, err := a.httpClient.Do(req)
	if err != nil {
		writeError(w, http.StatusBadGateway, "proxy_failed", err.Error())
		return
	}
	defer resp.Body.Close()

	copyProxyHeader(w, resp.Header, "Accept-Ranges")
	copyProxyHeader(w, resp.Header, "Cache-Control")
	copyProxyHeader(w, resp.Header, "Content-Disposition")
	copyProxyHeader(w, resp.Header, "Content-Length")
	copyProxyHeader(w, resp.Header, "Content-Range")
	copyProxyHeader(w, resp.Header, "Content-Type")
	copyProxyHeader(w, resp.Header, "ETag")
	copyProxyHeader(w, resp.Header, "Last-Modified")
	w.WriteHeader(resp.StatusCode)
	_, _ = io.Copy(w, resp.Body)
}

func (a *app) signObjectURL(provider cloudProvider, relativePath string, download bool) (string, time.Time, error) {
	switch provider {
	case cloudProviderGCS:
		return a.signGCSObjectURL(relativePath, download)
	case cloudProviderS3:
		return a.signS3ObjectURL(relativePath, download)
	default:
		return "", time.Time{}, fmt.Errorf("unsupported cloud provider %q", provider)
	}
}

func (a *app) signGCSObjectURL(relativePath string, download bool) (string, time.Time, error) {
	if a.cfg.gcs == nil || a.gcsStorage == nil {
		return "", time.Time{}, fmt.Errorf("provider %q is not configured", cloudProviderGCS)
	}
	if a.gcsSignerEmail == "" || len(a.gcsSignerKey) == 0 {
		return "", time.Time{}, fmt.Errorf("service-account signer is not initialized")
	}

	objectName := path.Join(a.cfg.gcs.prefix, relativePath)
	expiresAt := time.Now().Add(a.cfg.gcs.signTTL)
	opts := &storage.SignedURLOptions{
		GoogleAccessID: a.gcsSignerEmail,
		Method:         http.MethodGet,
		PrivateKey:     a.gcsSignerKey,
		Scheme:         storage.SigningSchemeV4,
		Expires:        expiresAt,
	}
	if download {
		base := path.Base(relativePath)
		opts.QueryParameters = url.Values{
			"response-content-disposition": []string{fmt.Sprintf("attachment; filename=%q", base)},
		}
	}
	url, err := storage.SignedURL(a.cfg.gcs.bucket, objectName, opts)
	if err != nil {
		return "", time.Time{}, err
	}
	return url, expiresAt, nil
}

func (a *app) signS3ObjectURL(relativePath string, download bool) (string, time.Time, error) {
	if a.cfg.s3 == nil || a.s3PresignClient == nil {
		return "", time.Time{}, fmt.Errorf("provider %q is not configured", cloudProviderS3)
	}

	objectName := path.Join(a.cfg.s3.prefix, relativePath)
	input := &s3.GetObjectInput{
		Bucket: awsv2.String(a.cfg.s3.bucket),
		Key:    awsv2.String(objectName),
	}
	if download {
		base := path.Base(relativePath)
		input.ResponseContentDisposition = awsv2.String(fmt.Sprintf("attachment; filename=%q", base))
	}

	expiresAt := time.Now().Add(a.cfg.s3.signTTL)
	presigned, err := a.s3PresignClient.PresignGetObject(context.Background(), input, func(options *s3.PresignOptions) {
		options.Expires = a.cfg.s3.signTTL
	})
	if err != nil {
		return "", time.Time{}, err
	}
	return presigned.URL, expiresAt, nil
}

func writeTextLines(w http.ResponseWriter, lines []string) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	if len(lines) == 0 {
		return
	}
	_, _ = io.WriteString(w, strings.Join(lines, "\n")+"\n")
}

func writeJSON(w http.ResponseWriter, status int, payload any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(payload)
}

func writeError(w http.ResponseWriter, status int, code string, message string) {
	writeJSON(w, status, map[string]string{
		"code":    code,
		"message": message,
	})
}

func copyProxyHeader(w http.ResponseWriter, src http.Header, key string) {
	if value := src.Get(key); value != "" {
		w.Header().Set(key, value)
	}
}
