// Copyright 2026 Кислов Роман Сергеевич
// SPDX-License-Identifier: Apache-2.0

package cleaner

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

func fakeApp(t *testing.T, root, name, id string) string {
	t.Helper()
	path := filepath.Join(root, name+".app")
	contents := filepath.Join(path, "Contents")
	if err := os.MkdirAll(contents, 0700); err != nil {
		t.Fatal(err)
	}
	info := fmt.Sprintf(`<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>%s</string><key>CFBundleName</key><string>%s</string></dict></plist>`, id, name)
	if err := os.WriteFile(filepath.Join(contents, "Info.plist"), []byte(info), 0600); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestAppsExactRelatedPathsAndFrameworkSymlinks(t *testing.T) {
	e, home := testEngine(t)
	e.appRoots = []string{filepath.Join(home, "Applications")}
	app := fakeApp(t, e.appRoots[0], "Example", "org.example.Example")
	if err := os.Symlink("Info.plist", filepath.Join(app, "Contents", "internal-link")); err != nil {
		t.Fatal(err)
	}
	// The matching identifier is suggested, a similar friendly name is not.
	put(t, filepath.Join(home, "Library", "Preferences", "org.example.Example.plist"), e.now())
	put(t, filepath.Join(home, "Library", "Application Support", "Example", "data"), e.now())
	r := e.ScanApps()
	if len(r.Apps) != 1 || len(r.Apps[0].Related) != 1 {
		t.Fatalf("unexpected apps: %+v", r)
	}
	var paths []string
	e.trash = func(path string) error { paths = append(paths, path); return nil }
	result := e.Clean([]string{r.Apps[0].Related[0].ID, r.Apps[0].ID})
	if len(result.Moved) != 2 || len(paths) != 2 || paths[0] != app {
		t.Fatal(result, paths)
	}
}

func TestAppsExcludeSystemAndInvalidBundleID(t *testing.T) {
	e, home := testEngine(t)
	e.appRoots = []string{filepath.Join(home, "Applications")}
	fakeApp(t, e.appRoots[0], "Apple", "com.apple.example")
	fakeApp(t, e.appRoots[0], "Invalid", "../../Documents")
	if len(e.ScanApps().Apps) != 0 {
		t.Fatal("unsafe app accepted")
	}
}

func TestAppsDuplicateIdentifierPreservesSharedData(t *testing.T) {
	e, home := testEngine(t)
	e.appRoots = []string{filepath.Join(home, "Applications")}
	fakeApp(t, e.appRoots[0], "One", "org.example.Shared")
	fakeApp(t, e.appRoots[0], "Two", "org.example.Shared")
	put(t, filepath.Join(home, "Library", "Preferences", "org.example.Shared.plist"), e.now())
	r := e.ScanApps()
	if len(r.Apps) != 2 {
		t.Fatal(r)
	}
	for _, app := range r.Apps {
		if len(app.Related) != 0 {
			t.Fatal("shared data must not be suggested")
		}
	}
}

func TestAppsRunningAndFailedUninstallPreserveData(t *testing.T) {
	for _, running := range []bool{true, false} {
		t.Run(fmt.Sprint(running), func(t *testing.T) {
			e, home := testEngine(t)
			e.appRoots = []string{filepath.Join(home, "Applications")}
			app := fakeApp(t, e.appRoots[0], "Example", "org.example.App")
			put(t, filepath.Join(home, "Library", "Preferences", "org.example.App.plist"), e.now())
			r := e.ScanApps()
			e.running = func(string) bool { return running }
			calls := 0
			e.trash = func(path string) error {
				calls++
				if path != app {
					t.Fatal("related data must be preserved")
				}
				return os.ErrPermission
			}
			result := e.Clean([]string{r.Apps[0].Related[0].ID, r.Apps[0].ID})
			if len(result.Moved) != 0 || len(result.Failed) != 2 {
				t.Fatal(result)
			}
			if running && calls != 0 {
				t.Fatal("running app sent to trash")
			}
		})
	}
}

func TestIndependentScanSnapshots(t *testing.T) {
	e, home := testEngine(t)
	e.appRoots = []string{filepath.Join(home, "Applications")}
	fakeApp(t, e.appRoots[0], "Example", "org.example.App")
	r := e.ScanApps()
	e.Scan()
	e.trash = func(string) error { return nil }
	if len(e.Clean([]string{r.Apps[0].ID}).Moved) != 1 {
		t.Fatal("cleaner scan invalidated app snapshot")
	}
}
