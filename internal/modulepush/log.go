package modulepush

import (
	"os"
	"sync"
)

// RotatingLog bounds both the sender's and the QMI children's diagnostics.
// Only current and previous files are retained; neither contains SMS PDUs.
type RotatingLog struct {
	mu   sync.Mutex
	path string
	file *os.File
	size int64
}

const maxLogBytes = 256 << 10

func OpenLog(path string) (*RotatingLog, error) {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0600)
	if err != nil {
		return nil, err
	}
	info, err := f.Stat()
	if err != nil {
		f.Close()
		return nil, err
	}
	return &RotatingLog{path: path, file: f, size: info.Size()}, nil
}

func (l *RotatingLog) Write(data []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	originalSize := len(data)
	if len(data) > maxLogBytes {
		data = data[len(data)-maxLogBytes:]
	}
	if l.size+int64(len(data)) > maxLogBytes {
		if err := l.file.Close(); err != nil {
			return 0, err
		}
		if err := os.Rename(l.path, l.path+".1"); err != nil {
			return 0, err
		}
		f, err := os.OpenFile(l.path, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0600)
		if err != nil {
			return 0, err
		}
		l.file = f
		l.size = 0
	}
	n, err := l.file.Write(data)
	l.size += int64(n)
	if err == nil {
		return originalSize, nil
	}
	return n, err
}
func (l *RotatingLog) Close() error { l.mu.Lock(); defer l.mu.Unlock(); return l.file.Close() }
