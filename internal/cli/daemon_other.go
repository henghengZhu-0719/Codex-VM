//go:build !darwin && !linux

package cli

import "fmt"

func daemonCommand(_ []string, streams IO) int {
 fmt.Fprintln(streams.Stderr,"daemon currently supports macOS and Linux")
 return 1
}
