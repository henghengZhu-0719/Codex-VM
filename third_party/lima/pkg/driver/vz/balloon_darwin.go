//go:build darwin && !no_vz

// SPDX-FileCopyrightText: Copyright The Lima Authors
// SPDX-License-Identifier: Apache-2.0

package vz

import (
	"errors"
	"fmt"

	"github.com/Code-Hex/vz/v3"
	"github.com/docker/go-units"
	"github.com/sirupsen/logrus"

	"github.com/lima-vm/lima/v2/pkg/driver"
)

const (
	minBalloonFloorBytes uint64 = 768 * 1024 * 1024
	balloonAlignBytes    uint64 = 1024 * 1024
)

func (l *LimaVzDriver) balloonBounds() (minBytes, maxBytes uint64, err error) {
	if l.Instance == nil || l.Instance.Config == nil || l.Instance.Config.Memory == nil {
		return 0, 0, errors.New("VM memory configuration is unavailable")
	}
	memInt, err := units.RAMInBytes(*l.Instance.Config.Memory)
	if err != nil || memInt <= 0 {
		return 0, 0, fmt.Errorf("invalid VM memory %q: %w", *l.Instance.Config.Memory, err)
	}
	maxBytes = uint64(memInt)
	minBytes = max(maxBytes/4, minBalloonFloorBytes)
	if minBytes > maxBytes {
		minBytes = maxBytes
	}
	return minBytes, maxBytes, nil
}

func (l *LimaVzDriver) traditionalBalloonDevice() (*vz.VirtioTraditionalMemoryBalloonDevice, error) {
	if l.machine == nil {
		return nil, errors.New("VM is not running")
	}
	l.machine.mu.Lock()
	stopped := l.machine.stopped
	l.machine.mu.Unlock()
	if stopped {
		return nil, errors.New("VM is stopped")
	}
	for _, dev := range l.machine.MemoryBalloonDevices() {
		if trad, ok := dev.(*vz.VirtioTraditionalMemoryBalloonDevice); ok {
			return trad, nil
		}
	}
	return nil, errors.New("no virtio traditional memory balloon device attached")
}

func (l *LimaVzDriver) GetMemoryBalloon() (*driver.MemoryBalloonInfo, error) {
	minBytes, maxBytes, err := l.balloonBounds()
	if err != nil {
		return nil, err
	}
	dev, err := l.traditionalBalloonDevice()
	if err != nil {
		return nil, err
	}
	target := dev.GetTargetVirtualMachineMemorySize()
	if target == 0 || target > maxBytes {
		target = maxBytes
	}
	return &driver.MemoryBalloonInfo{
		TargetBytes: target,
		MaxBytes:    maxBytes,
		MinBytes:    minBytes,
	}, nil
}

func (l *LimaVzDriver) SetMemoryBalloon(targetBytes uint64) (*driver.MemoryBalloonInfo, error) {
	minBytes, maxBytes, err := l.balloonBounds()
	if err != nil {
		return nil, err
	}
	dev, err := l.traditionalBalloonDevice()
	if err != nil {
		return nil, err
	}
	if targetBytes == 0 {
		targetBytes = maxBytes
	}
	// Align up to 1 MiB and clamp to safe [minBytes, maxBytes] range.
	aligned := ((targetBytes + balloonAlignBytes - 1) / balloonAlignBytes) * balloonAlignBytes
	if aligned < minBytes {
		aligned = minBytes
	}
	if aligned > maxBytes {
		aligned = maxBytes
	}
	dev.SetTargetVirtualMachineMemorySize(aligned)
	actual := dev.GetTargetVirtualMachineMemorySize()
	if actual == 0 {
		actual = aligned
	}
	logrus.Debugf("[VZ] memory balloon target set to %d MiB (max %d MiB)", actual>>20, maxBytes>>20)
	return &driver.MemoryBalloonInfo{
		TargetBytes: actual,
		MaxBytes:    maxBytes,
		MinBytes:    minBytes,
	}, nil
}
