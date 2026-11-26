//go:build !darwin && !linux

package cli

import "fmt"

func hostCommand(args []string, streams IO) int {
	fmt.Fprintln(streams.Stderr, "remote host commands are not supported on this platform")
	return 1
}

func remoteHostCommand(hostName string, args []string, streams IO) int {
	fmt.Fprintln(streams.Stderr, "remote host commands are not supported on this platform")
	return 1
}
