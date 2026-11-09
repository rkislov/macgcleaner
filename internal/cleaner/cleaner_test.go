// Copyright 2026 Кислов Роман Сергеевич
// SPDX-License-Identifier: Apache-2.0

package cleaner

import (
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

func testEngine(t *testing.T) (*Engine, string) {
	t.Helper()
	home, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	e := New(home)
	e.now = func() time.Time { return time.Date(2026, 11, 9, 12, 0, 0, 0, time.UTC) }
	for _, c := range e.Categories {
		if err := os.MkdirAll(c.Root, 0700); err != nil {
			t.Fatal(err)
		}
	}
	return e, home
}

func put(t *testing.T, p string, at time.Time) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(p), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte("cache content"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(p, at, at); err != nil {
		t.Fatal(err)
	}
}

func TestScanAgeAndCategories(t *testing.T) {
	e, _ := testEngine(t)
	old := e.now().Add(-60 * 24 * time.Hour)
	for _, c := range e.Categories {
		put(t, filepath.Join(c.Root, "old"), old)
		put(t, filepath.Join(c.Root, "recent"), e.now())
	}
	r := e.Scan()
	if len(r.Items) != 3 || r.Total != 39 {
		t.Fatalf("unexpected report: %+v", r)
	}
	for _, item := range r.Items {
		if item.Name != "old" {
			t.Fatal(item)
		}
	}
}

func TestEntireDirectoryMustBeOld(t *testing.T) {
	e, _ := testEngine(t)
	root := filepath.Join(e.Categories[0].Root, "app")
	old := e.now().Add(-60 * 24 * time.Hour)
	put(t, filepath.Join(root, "old"), old)
	put(t, filepath.Join(root, "recent"), e.now())
	_ = os.Chtimes(root, old, old)
	if len(e.Scan().Items) != 0 {
		t.Fatal("directory with a recent file must be excluded")
	}
	_ = os.Chtimes(filepath.Join(root, "recent"), old, old)
	if len(e.Scan().Items) != 1 {
		t.Fatal("old directory should be a candidate")
	}
}

func TestScanRejectsSymlinksAndSpecialFiles(t *testing.T) {
	e, home := testEngine(t)
	old := e.now().Add(-60 * 24 * time.Hour)
	outside := filepath.Join(home, "important.txt")
	put(t, outside, old)
	root := e.Categories[0].Root
	if err := os.Symlink(outside, filepath.Join(root, "link")); err != nil {
		t.Fatal(err)
	}
	if err := syscall.Mkfifo(filepath.Join(root, "fifo"), 0600); err != nil {
		t.Fatal(err)
	}
	folder := filepath.Join(root, "nested")
	put(t, filepath.Join(folder, "cache"), old)
	if err := os.Symlink(outside, filepath.Join(folder, "link")); err != nil {
		t.Fatal(err)
	}
	_ = os.Chtimes(folder, old, old)
	r := e.Scan()
	if len(r.Items) != 0 || len(r.Warnings) == 0 {
		t.Fatal("symlink candidates must be excluded with a warning")
	}
}

func TestCleanOnlySnapshotAndOnlyOnce(t *testing.T) {
	e, _ := testEngine(t)
	p := filepath.Join(e.Categories[0].Root, "old")
	put(t, p, e.now().Add(-60*24*time.Hour))
	r := e.Scan()
	calls := 0
	e.trash = func(path string) error {
		calls++
		if path != p {
			t.Fatalf("unexpected trash path: %s", path)
		}
		return nil
	}
	id := r.Items[0].ID
	result := e.Clean([]string{id, id, "../../important"})
	if calls != 1 || len(result.Moved) != 1 || len(result.Failed) != 1 {
		t.Fatal(result, calls)
	}
	if len(e.Clean([]string{id}).Moved) != 0 {
		t.Fatal("already moved id accepted")
	}
}

func TestCleanRejectsChangedFileAndReplacedInode(t *testing.T) {
	for _, replace := range []bool{false, true} {
		t.Run(map[bool]string{false: "modified", true: "replaced"}[replace], func(t *testing.T) {
			e, _ := testEngine(t)
			p := filepath.Join(e.Categories[0].Root, "old")
			old := e.now().Add(-60 * 24 * time.Hour)
			put(t, p, old)
			r := e.Scan()
			e.trash = func(string) error { t.Fatal("changed file passed to trash"); return nil }
			if replace {
				if err := os.Rename(p, p+".saved"); err != nil {
					t.Fatal(err)
				}
				put(t, p, old)
			} else {
				put(t, p, e.now())
			}
			result := e.Clean([]string{r.Items[0].ID})
			if len(result.Moved) != 0 || len(result.Failed) != 1 {
				t.Fatal(result)
			}
		})
	}
}

func TestCleanRejectsReplacedParentSymlink(t *testing.T) {
	e, home := testEngine(t)
	root := e.Categories[0].Root
	old := e.now().Add(-60 * 24 * time.Hour)
	put(t, filepath.Join(root, "old"), old)
	r := e.Scan()
	if err := os.Rename(root, root+".original"); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(home, root); err != nil {
		t.Fatal(err)
	}
	put(t, filepath.Join(home, "old"), old)
	e.trash = func(string) error { t.Fatal("symlink ancestor passed to trash"); return nil }
	result := e.Clean([]string{r.Items[0].ID})
	if len(result.Failed) != 1 || !strings.Contains(result.Failed[0].Message, "ссылка") {
		t.Fatal(result)
	}
}

func TestCleanPartialFailureAndRescanInvalidation(t *testing.T) {
	e, _ := testEngine(t)
	for _, name := range []string{"one", "two"} {
		put(t, filepath.Join(e.Categories[0].Root, name), e.now().Add(-60*24*time.Hour))
	}
	r := e.Scan()
	e.trash = func(p string) error {
		if filepath.Base(p) == "one" {
			return os.ErrPermission
		}
		return nil
	}
	result := e.Clean([]string{r.Items[0].ID, r.Items[1].ID})
	if len(result.Moved) != 1 || len(result.Failed) != 1 {
		t.Fatal(result)
	}
	e.Scan()
	if len(e.Clean([]string{result.Failed[0].ID}).Moved) != 0 {
		t.Fatal("stale snapshot id accepted")
	}
}
