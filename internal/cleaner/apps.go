// Copyright 2026 Кислов Роман Сергеевич
// SPDX-License-Identifier: Apache-2.0

package cleaner

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

type InstalledApp struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Path     string `json:"path"`
	BundleID string `json:"bundleID"`
	Bytes    int64  `json:"bytes"`
	Running  bool   `json:"running"`
	Related  []Item `json:"related"`
}
type AppReport struct {
	Apps     []InstalledApp `json:"apps"`
	Warnings []string       `json:"warnings"`
}

func (e *Engine) resetSnapshot(apps bool) {
	if e.snapshot == nil {
		e.snapshot = make(map[string]Item)
	}
	for id, item := range e.snapshot {
		if (item.Category == "applications" || item.Category == "leftovers") == apps {
			delete(e.snapshot, id)
		}
	}
}

func (e *Engine) candidate(path, category, owner string) (Item, error) {
	if err := safePath(path); err != nil {
		return Item{}, err
	}
	size, count, modified, fingerprint, err := inspectTree(path, category == "applications")
	if err != nil {
		return Item{}, err
	}
	id := make([]byte, 16)
	if _, err := rand.Read(id); err != nil {
		return Item{}, err
	}
	item := Item{ID: hex.EncodeToString(id), Name: filepath.Base(path), Category: category, Path: path, Bytes: size, Files: count, Modified: modified, fingerprint: fingerprint, root: filepath.Dir(path), ownerApp: owner}
	e.snapshot[item.ID] = item
	return item, nil
}

var bundlePattern = regexp.MustCompile(`^[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)+$`)

func (e *Engine) ScanApps() AppReport {
	e.resetSnapshot(true)
	r := AppReport{Apps: []InstalledApp{}, Warnings: []string{}}
	executable, _ := os.Executable()
	counts := make(map[string]int)
	for _, root := range e.appRoots {
		if err := safePath(root); err != nil {
			if !os.IsNotExist(err) {
				r.Warnings = append(r.Warnings, root+": "+err.Error())
			}
			continue
		}
		entries, err := os.ReadDir(root)
		if err != nil {
			r.Warnings = append(r.Warnings, err.Error())
			continue
		}
		for _, entry := range entries {
			if !entry.IsDir() || !strings.HasSuffix(strings.ToLower(entry.Name()), ".app") {
				continue
			}
			path := filepath.Join(root, entry.Name())
			if strings.HasPrefix(executable, path+string(os.PathSeparator)) {
				continue
			}
			var info struct {
				BundleID string `json:"bundleID"`
				Name     string `json:"name"`
			}
			if err := json.Unmarshal([]byte(bundleInfo(path)), &info); err != nil || !bundlePattern.MatchString(info.BundleID) {
				r.Warnings = append(r.Warnings, entry.Name()+": не удалось прочитать идентификатор программы")
				continue
			}
			if strings.HasPrefix(info.BundleID, "com.apple.") {
				continue
			}
			item, err := e.candidate(path, "applications", path)
			if err != nil {
				r.Warnings = append(r.Warnings, entry.Name()+": "+err.Error())
				continue
			}
			if info.Name == "" {
				info.Name = strings.TrimSuffix(entry.Name(), ".app")
			}
			r.Apps = append(r.Apps, InstalledApp{item.ID, info.Name, path, info.BundleID, item.Bytes, e.running(path), []Item{}})
			counts[info.BundleID]++
		}
	}
	for i := range r.Apps {
		app := &r.Apps[i]
		if counts[app.BundleID] > 1 {
			r.Warnings = append(r.Warnings, app.Name+": установлено несколько копий; общие данные не предлагаются к удалению")
			continue
		}
		// Exact bundle identifier only; never guess friendly names or touch shared containers.
		paths := []string{
			"Caches/" + app.BundleID, "Logs/" + app.BundleID,
			"Preferences/" + app.BundleID + ".plist", "Application Support/" + app.BundleID,
			"Saved Application State/" + app.BundleID + ".savedState",
			"HTTPStorages/" + app.BundleID, "WebKit/" + app.BundleID,
		}
		for _, relative := range paths {
			item, err := e.candidate(filepath.Join(e.home, "Library", filepath.FromSlash(relative)), "leftovers", app.Path)
			if err != nil {
				if !os.IsNotExist(err) {
					r.Warnings = append(r.Warnings, fmt.Sprintf("%s: %s", app.Name, err))
				}
				continue
			}
			app.Related = append(app.Related, item)
		}
	}
	sort.Slice(r.Apps, func(i, j int) bool { return strings.ToLower(r.Apps[i].Name) < strings.ToLower(r.Apps[j].Name) })
	return r
}
