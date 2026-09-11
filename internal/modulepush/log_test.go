package modulepush

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

func TestLogBoundedAcrossRotation(t *testing.T) {
	path := filepath.Join(t.TempDir(), "notify.log")
	writer, err := OpenLog(path)
	if err != nil {
		t.Fatal(err)
	}
	defer writer.Close()
	for i := 0; i < 3; i++ {
		payload := bytes.Repeat([]byte{'x'}, maxLogBytes+100)
		if n, err := writer.Write(payload); err != nil || n != len(payload) {
			t.Fatal(n, err)
		}
	}
	for _, name := range []string{path, path + ".1"} {
		info, err := os.Stat(name)
		if err != nil {
			t.Fatal(err)
		}
		if info.Size() > maxLogBytes || info.Mode().Perm() != 0600 {
			t.Fatal("unbounded/insecure log", info)
		}
	}
}
