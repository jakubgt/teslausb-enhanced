package main

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestNormalizePrefix(t *testing.T) {
	t.Parallel()

	cases := []struct {
		in   string
		want string
	}{
		{"", ""},
		{"TeslaCam", "TeslaCam/"},
		{"/TeslaCam/", "TeslaCam/"},
		{"  TeslaCam/SavedClips  ", "TeslaCam/SavedClips/"},
	}

	for _, tc := range cases {
		if got := normalizePrefix(tc.in); got != tc.want {
			t.Fatalf("normalizePrefix(%q)=%q want=%q", tc.in, got, tc.want)
		}
	}
}

func TestNormalizeRelativePath(t *testing.T) {
	t.Parallel()

	good := []string{
		"RecentClips/2025-01-01/2025-01-01_00-00-00-front.mp4",
		"SavedClips/2025-01-01_00-00-00/event.json",
	}
	for _, input := range good {
		got, err := normalizeRelativePath(input)
		if err != nil {
			t.Fatalf("normalizeRelativePath(%q) unexpected error: %v", input, err)
		}
		if got != input {
			t.Fatalf("normalizeRelativePath(%q)=%q", input, got)
		}
	}

	bad := []string{"", "/x", "../x", "x/../y", "x//y", "x\\y"}
	for _, input := range bad {
		if _, err := normalizeRelativePath(input); err == nil {
			t.Fatalf("normalizeRelativePath(%q) expected error", input)
		}
	}
}

func TestRelativeFromObjectName(t *testing.T) {
	t.Parallel()

	prefix := "TeslaCam/"
	cases := []struct {
		name string
		ok   bool
	}{
		{"TeslaCam/RecentClips/2025-01-01/file.mp4", true},
		{"TeslaCam/RecentClips/2025-01-01/file.txt", false},
		{"TeslaCam/SavedClips/2025-01-01/event.json", true},
		{"Other/RecentClips/file.mp4", false},
		{"TeslaCam/", false},
	}

	for _, tc := range cases {
		_, ok := relativeFromObjectName(prefix, tc.name)
		if ok != tc.ok {
			t.Fatalf("relativeFromObjectName(%q) ok=%t want=%t", tc.name, ok, tc.ok)
		}
	}
}

func TestBuildLocalVideoList(t *testing.T) {
	t.Parallel()

	root := t.TempDir()
	mustWrite := func(rel string) {
		p := filepath.Join(root, filepath.FromSlash(rel))
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatalf("mkdir: %v", err)
		}
		if err := os.WriteFile(p, []byte("x"), 0o644); err != nil {
			t.Fatalf("write: %v", err)
		}
	}

	mustWrite("RecentClips/2025-01-01/2025-01-01_00-00-00-front.mp4")
	mustWrite("SentryClips/2025-01-01_00-00-00/event.json")
	mustWrite("SentryClips/2025-01-01_00-00-00/thumb.png")
	mustWrite("SentryClips/2025-01-01_00-00-00/ignore.txt")

	got, err := buildLocalVideoList(root)
	if err != nil {
		t.Fatalf("buildLocalVideoList: %v", err)
	}

	want := []string{
		"RecentClips/2025-01-01/2025-01-01_00-00-00-front.mp4",
		"SentryClips/2025-01-01_00-00-00/event.json",
		"SentryClips/2025-01-01_00-00-00/thumb.png",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got=%v want=%v", got, want)
	}
}
