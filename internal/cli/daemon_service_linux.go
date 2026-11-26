//go:build linux

package cli

import "fmt"

func daemonService(command, state string, streams IO) error {
 return fmt.Errorf("daemon %s: launchd management requires macOS; use daemon serve on Linux", command)
}
