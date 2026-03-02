package main

import (
	"cloud.google.com/go/storage"
	"context"
	"encoding/json"
	"errors"
	"fmt"
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
	cfg           config
	storageClient *storage.Client
	signerEmail   string
	signerPrivKey []byte
	httpClient    *http.Client
}

type serviceAccountKey struct {
	ClientEmail string `json:"client_email"`
	PrivateKey  string `json:"private_key"`
}

func newApp(ctx context.Context, cfg config) (*app, error) {
	result := &app{
		cfg: cfg,
		httpClient: &http.Client{
			Timeout: 30 * time.Second,
		},
	}

	if !cfg.cloudEnabled() {
		return result, nil
	}

	if cfg.keyFile == "" {
		return nil, fmt.Errorf("GOOGLE_APPLICATION_CREDENTIALS is required when GCS_BUCKET is set")
	}

	storageClient, err := storage.NewClient(ctx)
	if err != nil {
		return nil, fmt.Errorf("create storage client: %w", err)
	}
	result.storageClient = storageClient

	keyBytes, err := os.ReadFile(cfg.keyFile)
	if err != nil {
		return nil, fmt.Errorf("read service-account key: %w", err)
	}
	var key serviceAccountKey
	if err := json.Unmarshal(keyBytes, &key); err != nil {
		return nil, fmt.Errorf("parse service-account key: %w", err)
	}
	if strings.TrimSpace(key.ClientEmail) == "" || strings.TrimSpace(key.PrivateKey) == "" {
		return nil, fmt.Errorf("service-account key missing client_email/private_key")
	}
	result.signerEmail = key.ClientEmail
	result.signerPrivKey = []byte(key.PrivateKey)

	return result, nil
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
	if a.storageClient != nil {
		return a.storageClient.Close()
	}
	return nil
}

func (a *app) handleCloudHealth(w http.ResponseWriter, _ *http.Request) {
	resp := map[string]any{
		"enabled": a.cfg.cloudEnabled(),
		"bucket":  a.cfg.bucket,
		"prefix":  strings.TrimSuffix(a.cfg.prefix, "/"),
	}
	if !a.cfg.cloudEnabled() {
		writeJSON(w, http.StatusOK, resp)
		return
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	it := a.storageClient.Bucket(a.cfg.bucket).Objects(ctx, &storage.Query{Prefix: a.cfg.prefix})
	if _, err := it.Next(); err != nil && !errors.Is(err, iterator.Done) {
		resp["healthy"] = false
		resp["error"] = err.Error()
		writeJSON(w, http.StatusOK, resp)
		return
	}

	resp["healthy"] = true
	writeJSON(w, http.StatusOK, resp)
}

func (a *app) handleCloudVideoList(w http.ResponseWriter, _ *http.Request) {
	if !a.cfg.cloudEnabled() {
		writeError(w, http.StatusNotFound, "cloud_disabled", "cloud viewer is not configured")
		return
	}

	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()

	it := a.storageClient.Bucket(a.cfg.bucket).Objects(ctx, &storage.Query{Prefix: a.cfg.prefix})
	lines := make([]string, 0, 4096)
	for {
		attrs, err := it.Next()
		if errors.Is(err, iterator.Done) {
			break
		}
		if err != nil {
			writeError(w, http.StatusBadGateway, "gcs_list_failed", err.Error())
			return
		}
		if attrs == nil {
			continue
		}
		if rel, ok := relativeFromObjectName(a.cfg.prefix, attrs.Name); ok {
			lines = append(lines, rel)
		}
	}

	lines = sortedUniqueLines(lines)
	writeTextLines(w, lines)
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

	relPath, err := normalizeRelativePath(r.URL.Query().Get("path"))
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_path", err.Error())
		return
	}

	download := r.URL.Query().Get("download") == "1"
	signedURL, expiresAt, err := a.signObjectURL(relPath, download)
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

	relPath, err := normalizeRelativePath(r.URL.Query().Get("path"))
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_path", err.Error())
		return
	}
	download := r.URL.Query().Get("download") == "1"
	signedURL, _, err := a.signObjectURL(relPath, download)
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

func (a *app) signObjectURL(relativePath string, download bool) (string, time.Time, error) {
	if a.signerEmail == "" || len(a.signerPrivKey) == 0 {
		return "", time.Time{}, fmt.Errorf("service-account signer is not initialized")
	}

	objectName := path.Join(a.cfg.prefix, relativePath)
	expiresAt := time.Now().Add(a.cfg.signTTL)
	opts := &storage.SignedURLOptions{
		GoogleAccessID: a.signerEmail,
		Method:         http.MethodGet,
		PrivateKey:     a.signerPrivKey,
		Scheme:         storage.SigningSchemeV4,
		Expires:        expiresAt,
	}
	if download {
		base := path.Base(relativePath)
		opts.QueryParameters = url.Values{
			"response-content-disposition": []string{fmt.Sprintf("attachment; filename=%q", base)},
		}
	}
	url, err := storage.SignedURL(a.cfg.bucket, objectName, opts)
	if err != nil {
		return "", time.Time{}, err
	}
	return url, expiresAt, nil
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
