// Copyright 2026 Кислов Роман Сергеевич
// SPDX-License-Identifier: Apache-2.0

package cleaner

/*
#cgo LDFLAGS: -framework Foundation -framework AppKit
#include <stdlib.h>
char *mac_trash(const char *path);
char *mac_bundle_info(const char *path);
int mac_app_running(const char *path);
*/
import "C"
import (
	"fmt"
	"unsafe"
)

func bundleInfo(path string) string {
	p := C.CString(path)
	defer C.free(unsafe.Pointer(p))
	value := C.mac_bundle_info(p)
	if value == nil {
		return "{}"
	}
	defer C.free(unsafe.Pointer(value))
	return C.GoString(value)
}

func appRunning(path string) bool {
	p := C.CString(path)
	defer C.free(unsafe.Pointer(p))
	return C.mac_app_running(p) != 0
}

func moveToTrash(path string) error {
	p := C.CString(path)
	defer C.free(unsafe.Pointer(p))
	message := C.mac_trash(p)
	if message == nil {
		return nil
	}
	defer C.free(unsafe.Pointer(message))
	return fmt.Errorf("Корзина: %s", C.GoString(message))
}
