// Copyright 2026 Кислов Роман Сергеевич
// SPDX-License-Identifier: Apache-2.0

package cleaner

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"syscall"
	"time"
)

type Category struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	Description string `json:"description"`
	Days        int    `json:"days"`
	Root        string `json:"-"`
}

type Item struct {
	ID          string    `json:"id"`
	Category    string    `json:"category"`
	Name        string    `json:"name"`
	Path        string    `json:"path"`
	Bytes       int64     `json:"bytes"`
	Files       int       `json:"files"`
	Modified    time.Time `json:"modified"`
	fingerprint string
	root        string
	ownerApp    string
}

type Report struct {
	Items      []Item     `json:"items"`
	Warnings   []string   `json:"warnings"`
	Categories []Category `json:"categories"`
	ScannedAt  time.Time  `json:"scannedAt"`
	Total      int64      `json:"total"`
}

type Failure struct {
	ID      string `json:"id"`
	Message string `json:"message"`
}
type Result struct {
	Moved  []string  `json:"moved"`
	Failed []Failure `json:"failed"`
	Bytes  int64     `json:"bytes"`
}

type Engine struct {
	Categories []Category
	snapshot   map[string]Item
	now        func() time.Time
	trash      func(string) error
	home       string
	appRoots   []string
	running    func(string) bool
}

func New(home string) *Engine {
	return &Engine{
		Categories: []Category{
			{"caches", "Кэши приложений", "Не изменялись минимум 7 дней. Приложения создадут их заново.", 7, filepath.Join(home, "Library/Caches")},
			{"logs", "Старые журналы", "Диагностические логи старше 30 дней.", 30, filepath.Join(home, "Library/Logs")},
			{"xcode", "Сборки Xcode", "DerivedData старше 14 дней. Следующая сборка займёт больше времени.", 14, filepath.Join(home, "Library/Developer/Xcode/DerivedData")},
		},
		now: time.Now, trash: moveToTrash, home: home,
		appRoots: []string{"/Applications", filepath.Join(home, "Applications")}, running: appRunning,
	}
}

// Strictly reject symlinks in the entire path, including ancestor directories.
func safePath(path string) error {
	path = filepath.Clean(path)
	if !filepath.IsAbs(path) {
		return fmt.Errorf("требуется абсолютный путь")
	}
	for p := path; ; p = filepath.Dir(p) {
		st, err := os.Lstat(p)
		if err != nil {
			return err
		}
		if st.Mode()&os.ModeSymlink != 0 {
			return fmt.Errorf("символическая ссылка: %s", p)
		}
		if p == filepath.Dir(p) {
			break
		}
	}
	return nil
}

// Inspect every descendant. A single unreadable, special, or linked entry excludes
// the whole candidate. Hash metadata to detect changes before moving a directory.
func inspect(path string) (int64, int, time.Time, string, error) {
	return inspectTree(path, false)
}

func inspectTree(path string, bundle bool) (int64, int, time.Time, string, error) {
	h := sha256.New()
	var bytes int64
	var files int
	var newest time.Time
	err := filepath.WalkDir(path, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		st, err := d.Info()
		if err != nil {
			return err
		}
		link := st.Mode()&os.ModeSymlink != 0
		if !st.IsDir() && !st.Mode().IsRegular() && !(bundle && link && p != path) {
			return fmt.Errorf("ссылка или специальный файл: %s", p)
		}
		if link {
			target, err := os.Readlink(p)
			if err != nil {
				return err
			}
			fmt.Fprintf(h, "link:%q;", target)
		}
		if st.ModTime().After(newest) {
			newest = st.ModTime()
		}
		if st.Mode().IsRegular() {
			bytes += st.Size()
			files++
		}
		if s, ok := st.Sys().(*syscall.Stat_t); ok {
			fmt.Fprintf(h, "%q:%d:%d:%d:%d:%d:%d;", p, s.Dev, s.Ino, st.Mode(), st.Size(), st.ModTime().UnixNano(), s.Ctimespec.Nano())
		} else {
			return fmt.Errorf("нет метаданных: %s", p)
		}
		return nil
	})
	return bytes, files, newest, hex.EncodeToString(h.Sum(nil)), err
}

func (e *Engine) Scan() Report {
	e.resetSnapshot(false)
	r := Report{Items: []Item{}, Warnings: []string{}, Categories: e.Categories, ScannedAt: e.now()}
	for _, c := range e.Categories {
		if err := safePath(c.Root); err != nil {
			if !os.IsNotExist(err) {
				r.Warnings = append(r.Warnings, c.Name+": "+err.Error())
			}
			continue
		}
		entries, err := os.ReadDir(c.Root)
		if err != nil {
			r.Warnings = append(r.Warnings, c.Name+": "+err.Error())
			continue
		}
		cutoff := e.now().Add(-time.Duration(c.Days) * 24 * time.Hour)
		var skipped int
		for _, entry := range entries {
			p := filepath.Join(c.Root, entry.Name())
			size, count, newest, fingerprint, err := inspect(p)
			if err != nil {
				skipped++
				continue
			}
			if size == 0 || !newest.Before(cutoff) {
				continue
			}
			id := make([]byte, 16)
			if _, err := rand.Read(id); err != nil {
				r.Warnings = append(r.Warnings, err.Error())
				continue
			}
			item := Item{ID: hex.EncodeToString(id), Category: c.ID, Name: entry.Name(), Path: p, Bytes: size, Files: count, Modified: newest, fingerprint: fingerprint, root: c.Root}
			e.snapshot[item.ID] = item
			r.Items = append(r.Items, item)
			r.Total += size
		}
		if skipped > 0 {
			r.Warnings = append(r.Warnings, fmt.Sprintf("%s: пропущено объектов с ограниченным доступом, ссылками или специальными файлами: %d", c.Name, skipped))
		}
	}
	sort.Slice(r.Items, func(i, j int) bool { return r.Items[i].Bytes > r.Items[j].Bytes })
	return r
}

func (e *Engine) Clean(ids []string) Result {
	r := Result{Moved: []string{}, Failed: []Failure{}}
	// Move application bundles first. If that fails, preserve their selected data.
	ids = append([]string(nil), ids...)
	sort.SliceStable(ids, func(i, j int) bool {
		return e.snapshot[ids[i]].Category == "applications" && e.snapshot[ids[j]].Category != "applications"
	})
	blockedApps := make(map[string]bool)
	seen := make(map[string]bool)
	for _, id := range ids {
		if seen[id] {
			continue
		}
		seen[id] = true
		item, ok := e.snapshot[id]
		if !ok {
			r.Failed = append(r.Failed, Failure{id, "Объект отсутствует в текущем сканировании"})
			continue
		}
		err := safePath(item.Path)
		if err == nil && item.ownerApp != "" {
			if blockedApps[item.ownerApp] {
				err = fmt.Errorf("программа не удалена; связанные данные сохранены")
			} else if e.running(item.ownerApp) {
				err = fmt.Errorf("программа запущена; сначала закройте её")
			}
		}
		if err == nil && filepath.Dir(item.Path) != item.root {
			err = fmt.Errorf("путь вне разрешённой папки")
		}
		if err == nil {
			_, _, _, fingerprint, inspectErr := inspectTree(item.Path, item.Category == "applications")
			err = inspectErr
			if err == nil && fingerprint != item.fingerprint {
				err = fmt.Errorf("объект изменился после сканирования; выполните сканирование заново")
			}
		}
		if err == nil {
			err = e.trash(item.Path)
		}
		if err != nil {
			if item.Category == "applications" {
				blockedApps[item.Path] = true
			}
			r.Failed = append(r.Failed, Failure{id, item.Name + ": " + err.Error()})
			continue
		}
		r.Moved = append(r.Moved, id)
		r.Bytes += item.Bytes
		delete(e.snapshot, id)
	}
	return r
}
