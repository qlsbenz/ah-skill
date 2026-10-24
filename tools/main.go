package main

import (
	"fmt"
	"os"

	"ah-skills/tools/internal/cli"
)

func main() {
	if err := cli.Run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "ah-skills: error:", err)
		os.Exit(1)
	}
}
