package main

import (
	"fmt"
	"path"
	"path/filepath"
	"sort"
	"strings"
)

var allowedMediaExtensions = map[string]struct{}{
	".jpeg": {},
	".jpg":  {},
	".json": {},
	".mp4":  {},
	".png":  {},
}

func normalizePrefix(raw string) string {
	trimmed := strings.TrimSpace(raw)
	trimmed = strings.Trim(trimmed, "/")
	if trimmed == "" {
		return ""
	}
	return trimmed + "/"
}

func normalizeRelativePath(raw string) (string, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return "", fmt.Errorf("path must not be empty")
	}
	if strings.Contains(raw, "\\") {
		return "", fmt.Errorf("path must not contain backslashes")
	}
	if strings.HasPrefix(raw, "/") {
		return "", fmt.Errorf("path must be relative")
	}
	if strings.Contains(raw, "..") {
		return "", fmt.Errorf("path must not contain dot-dot segments")
	}

	clean := path.Clean(raw)
	if clean == "." || clean == "" {
		return "", fmt.Errorf("path must not be empty")
	}
	if strings.HasPrefix(clean, "../") || clean == ".." {
		return "", fmt.Errorf("path must stay within root")
	}
	if clean != raw {
		return "", fmt.Errorf("path must be normalized")
	}
	return clean, nil
}

func relativeFromObjectName(prefix string, objectName string) (string, bool) {
	if strings.HasSuffix(objectName, "/") {
		return "", false
	}

	rel := objectName
	if prefix != "" {
		if !strings.HasPrefix(objectName, prefix) {
			return "", false
		}
		rel = strings.TrimPrefix(objectName, prefix)
	}

	rel = strings.TrimPrefix(rel, "/")
	if rel == "" {
		return "", false
	}

	if _, err := normalizeRelativePath(rel); err != nil {
		return "", false
	}
	if !isSupportedMediaExt(rel) {
		return "", false
	}
	return rel, true
}

func isSupportedMediaExt(relativePath string) bool {
	ext := strings.ToLower(filepath.Ext(relativePath))
	_, ok := allowedMediaExtensions[ext]
	return ok
}

func sortedUniqueLines(lines []string) []string {
	if len(lines) == 0 {
		return nil
	}
	set := make(map[string]struct{}, len(lines))
	for _, line := range lines {
		set[line] = struct{}{}
	}
	uniq := make([]string, 0, len(set))
	for line := range set {
		uniq = append(uniq, line)
	}
	sort.Strings(uniq)
	return uniq
}
