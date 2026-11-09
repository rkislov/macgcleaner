// Copyright 2026 Кислов Роман Сергеевич
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"macgcleaner/internal/cleaner"
	"os"
)

type Request struct {
	Command string   `json:"command"`
	IDs     []string `json:"ids"`
}

func main() {
	home, err := os.UserHomeDir()
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	engine := cleaner.New(home)
	input := bufio.NewScanner(os.Stdin)
	input.Buffer(make([]byte, 4096), 4*1024*1024)
	output := json.NewEncoder(os.Stdout)
	for input.Scan() {
		var req Request
		if err := json.Unmarshal(input.Bytes(), &req); err != nil {
			_ = output.Encode(map[string]string{"error": err.Error()})
			continue
		}
		switch req.Command {
		case "scan":
			_ = output.Encode(engine.Scan())
		case "apps":
			_ = output.Encode(engine.ScanApps())
		case "clean":
			_ = output.Encode(engine.Clean(req.IDs))
		default:
			_ = output.Encode(map[string]string{"error": "Неизвестная команда"})
		}
	}
	if err := input.Err(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
