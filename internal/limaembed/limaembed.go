// Package limaembed runs what Lima's libraries expect of limactl: they start
// the current executable again for some commands (`hostagent`, from
// instance.Start), and look for the guest agent and the templates next to it.
package limaembed

import (
	"context"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/sirupsen/logrus"
	"github.com/spf13/cobra"

	"github.com/lima-vm/lima/v2/pkg/debugutil"
	"github.com/lima-vm/lima/v2/pkg/driver/external/server"
	"github.com/lima-vm/lima/v2/pkg/envutil"
	"github.com/lima-vm/lima/v2/pkg/hostagent/dns"
	"github.com/lima-vm/lima/v2/pkg/networks/usernet"
	"github.com/lima-vm/lima/v2/pkg/osutil"
	"github.com/lima-vm/sshocker/pkg/reversesshfs"

	"github.com/sylvinus/agent-vm/internal/guard"
	"github.com/sylvinus/agent-vm/internal/netguard"
 "github.com/sylvinus/agent-vm/internal/netgate"
	"github.com/sylvinus/agent-vm/internal/state"
)

// Run runs args (os.Args[1:]) when they are a command Lima's libraries start
// this executable for, as limactl would, and reports whether they were. Such
// a command never returns: it exits.
func Run(args []string) bool {
	i := 0
	for i < len(args) && args[i] == "--debug" {
		i++
	}
	if i == len(args) || args[i] != "hostagent" {
		return false
	}
	if runtime.GOOS == "windows" {
		windowsPath()
	}
	// Lima's own port forwarder, the one patched to never take a port a
	// program of the host serves; not the ssh one.
	os.Unsetenv("LIMA_SSH_PORT_FORWARDER")
	// What the guest may reach (netguard): every connection it opens is made
	// here, by the instance's netstack. An unreadable policy stops the VM
	// rather than leave it open.
	st, err := state.Default()
	if err != nil {
		logrus.Fatal(err)
	}
	policy, err := netguard.Load(string(st))
	if err != nil {
		logrus.Fatal(err)
	}
	usernet.Outbound = policy.Allows
	if len(policy.Domains) > 0 {
		// Both resolvers the guest can reach: the gateway's, which every
		// query gets whatever the guest's iptables say, and the hostagent's.
		usernet.Names, usernet.Answered = policy.Name, policy.Answered
		dns.Names, dns.Answered = policy.Name, policy.Answered
	}
	// Managed mode installs host-owned transport hooks and starts CLOSED,
	// opening only if the host-side proxy, DoH, and fail-closed probes pass.
	// Initialization failures abort startup rather than fall back to legacy networking.
	var stopManagedNetwork func()
	if configPath := managedNetworkRequested(); configPath != "" {
		gate, check, err := installManagedNetwork(configPath, policy, args[len(args)-1])
		if err != nil {
			logrus.Fatal(err)
		}
		wrappedCheck := wrapCheckWithGateAuth(gate, check)
		initEpoch := gate.BeginCheck()
		if !hostProbesPassed(wrappedCheck(context.Background(), initEpoch)) {
			logrus.Warn("managed network startup probe failed; gate remains closed")
		}
		control, err := netgate.StartControl(filepath.Join(string(st), ".netgate-private"), gate, wrappedCheck)
		if err != nil {
			logrus.Fatal(err)
		}
		stopManagedNetwork = func() { _ = control.Close() }
	}
	// The user is asked before the VM changes a file their machine runs on
	// its own (guard): the shares' SFTP server runs here.
	g, err := guard.Load(string(st), args[len(args)-1])
	if err != nil {
		logrus.Fatal(err)
	}
	reversesshfs.Guard = g.Allow
	root := &cobra.Command{
		Use:           "agent-vm",
		SilenceUsage:  true,
		SilenceErrors: true,
		PersistentPreRun: func(cmd *cobra.Command, _ []string) {
			if debug, _ := cmd.Flags().GetBool("debug"); debug {
				logrus.SetLevel(logrus.DebugLevel)
				debugutil.Debug = true
			}
		},
	}
	root.PersistentFlags().Bool("debug", false, "debug mode")
	root.AddCommand(newHostagentCommand())
	root.SetArgs(args)
	// Its events, as limactl's, and a notice for each port it forwards. The
	// instance is the last argument.
	root.SetOut(newEventWatch(os.Stdout, args[len(args)-1]))
	err = root.Execute()
	if stopManagedNetwork != nil { stopManagedNetwork() }
	server.Disconnect()
	osutil.HandleExitError(err)
	if err != nil {
		logrus.Fatal(err)
	}
	os.Exit(0)
	return true
}

// hostProbesPassed reports whether all three host-measurable checks passed.
func hostProbesPassed(report netgate.SafetyReport) bool {
	states := make(map[string]netgate.CheckState, len(report.Checks))
	for _, check := range report.Checks {
		states[check.ID] = check.State
	}
	return states["proxy_transport"] == netgate.Passed &&
		states["dns_transport"] == netgate.Passed &&
		states["fail_closed"] == netgate.Passed
}

// wrapCheckWithGateAuth runs check and authorizes gate for 24h when host probes pass,
// or revokes the gate if any host probe fails.
func wrapCheckWithGateAuth(gate *netgate.Gate, check func(context.Context, uint64) netgate.SafetyReport) func(context.Context, uint64) netgate.SafetyReport {
	return func(ctx context.Context, epoch uint64) netgate.SafetyReport {
		report := check(ctx, epoch)
		if hostProbesPassed(report) {
			_ = gate.Authorize(epoch, 24*time.Hour)
		} else {
			gate.Revoke()
		}
		return report
	}
}

// windowsPath puts QEMU's usual folders on PATH, as limactl's main does.
func windowsPath() {
	if extras, ok := os.LookupEnv("_LIMA_WINDOWS_EXTRA_PATH"); ok && strings.TrimSpace(extras) != "" {
		_ = os.Setenv("PATH", strings.TrimSpace(extras)+string(filepath.ListSeparator)+os.Getenv("PATH"))
	}
	p := os.Getenv("PATH")
	if np := envutil.AppendDirsToPath(p, envutil.PlatformCommonToolDirs); np != p {
		_ = os.Setenv("PATH", np)
	}
}
