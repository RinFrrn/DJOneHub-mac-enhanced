// djonehub-pairing-prepare creates one module's provisioning artifacts on a Mac.
// Only registry.json is installed on the module. The invitations stay offline.
package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/iniwex5/vohive/internal/modulepairing"
)

func main() {
	destination := flag.String("out", "", "new private output directory (required)")
	flag.Parse()
	if err := prepare(*destination, time.Now()); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	fmt.Println("Created private module identity, bootstrap.json and recovery.json. Install only registry.json on the module; keep recovery.json offline. No device was modified.")
}

func prepare(destination string, now time.Time) error {
	if destination == "" {
		return errors.New("a new output directory is required")
	}
	path, err := filepath.Abs(destination)
	if err != nil {
		return errors.New("invalid output directory")
	}
	// Reserve the destination without replacing any existing identity or backup.
	if err := os.Mkdir(path, 0700); err != nil {
		return errors.New("output directory must not already exist and its parent must exist")
	}
	complete := false
	defer func() {
		if !complete {
			_ = os.RemoveAll(path)
		}
	}()
	store, err := modulepairing.Open(filepath.Join(path, "registry.json"))
	if err != nil {
		return err
	}
	defer store.Close()
	bootstrap, recovery, err := store.Initialize(now)
	if err != nil {
		return err
	}
	for _, artifact := range []struct {
		name  string
		value modulepairing.Invitation
	}{
		{"bootstrap.json", bootstrap}, {"recovery.json", recovery},
	} {
		data, err := json.MarshalIndent(artifact.value, "", "  ")
		if err != nil {
			return errors.New("cannot encode pairing artifact")
		}
		file, err := os.OpenFile(filepath.Join(path, artifact.name), os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
		if err != nil {
			return errors.New("cannot save pairing artifact")
		}
		_, err = file.Write(append(data, '\n'))
		if err == nil {
			err = file.Sync()
		}
		closeErr := file.Close()
		if err != nil || closeErr != nil {
			return errors.New("cannot persist pairing artifact")
		}
	}
	dir, err := os.Open(path)
	if err != nil {
		return errors.New("cannot persist pairing directory")
	}
	err = dir.Sync()
	dir.Close()
	if err != nil {
		return errors.New("cannot persist pairing directory")
	}
	parent, err := os.Open(filepath.Dir(path))
	if err != nil {
		return errors.New("cannot persist output directory")
	}
	err = parent.Sync()
	parent.Close()
	if err != nil {
		return errors.New("cannot persist output directory")
	}
	complete = true
	return nil
}
