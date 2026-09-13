package modulepush

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"slices"
	"strconv"
	"strings"
	"time"
	"unicode"

	"github.com/iniwex5/vohive/pkg/smscodec"
)

// Snapshot is emitted only after a complete, successful read. An absent/error
// snapshot must never clear the previous state or re-arm incoming calls.
type Snapshot struct {
	Kind        string            `json:"kind"`
	Storage     int               `json:"storage,omitempty"`
	Calls       []int             `json:"calls,omitempty"`
	CallNumbers map[string]string `json:"call_numbers,omitempty"`
	PDUs        []string          `json:"pdus,omitempty"`
}

type Delivery struct {
	ID        string    `json:"id"`
	Kind      string    `json:"kind"`
	Transport string    `json:"transport"`
	Expires   time.Time `json:"expires"`
	Next      time.Time `json:"next"`
	Attempts  int       `json:"attempts"`
	Detail    string    `json:"detail,omitempty"`
}

type State struct {
	Version   int                      `json:"version"`
	SMS       map[int][]string         `json:"sms"`
	Queue     []Delivery               `json:"queue"`
	Sequence  uint64                   `json:"sequence"`
	Multipart map[string]*multipartSMS `json:"multipart,omitempty"`
	// Calls are intentionally not restored across boot: a currently ringing
	// call deserves a fresh alert, whereas historical SMS must remain silent.
	calls []int
}

type multipartSMS struct {
	Key       string         `json:"key"` // Hash of sender and concatenation metadata, never the sender itself.
	Timestamp time.Time      `json:"timestamp"`
	Expires   time.Time      `json:"expires"`
	Total     int            `json:"total"`
	IDs       map[int]string `json:"ids"`
	Text      map[int]string `json:"text,omitempty"`
	Silent    bool           `json:"silent,omitempty"`
	Notified  bool           `json:"notified,omitempty"`
}

type smsPart struct {
	id, key, text string
	timestamp     time.Time
	concat        smscodec.ConcatInfo
}

func NewState() *State { return &State{Version: 1, SMS: make(map[int][]string)} }

func (s *State) Apply(event Snapshot, options EventOptions, now time.Time) (bool, error) {
	switch event.Kind {
	case "calls":
		if len(event.Calls) > 8 {
			return false, errors.New("too many calls")
		}
		for index, id := range event.Calls {
			if id < 1 || id > 255 {
				return false, errors.New("invalid call ID")
			}
			if slices.Contains(event.Calls[:index], id) {
				return false, errors.New("duplicate call ID")
			}
		}
		changed := false
		for _, id := range event.Calls {
			if !slices.Contains(s.calls, id) {
				detail := ""
				if options.ShowCallNumber {
					detail = normalizedCallNumber(event.CallNumbers[strconv.Itoa(id)])
				}
				s.enqueue("call", fmt.Sprintf("call-%d", id), options.Transports, detail, now)
				changed = true
			}
		}
		// Cancel pending retries immediately after the modem stops ringing.
		for _, id := range s.calls {
			if !slices.Contains(event.Calls, id) {
				prefix := fmt.Sprintf("call-%d/", id)
				s.Queue = slices.DeleteFunc(s.Queue, func(d Delivery) bool { return len(d.ID) >= len(prefix) && d.ID[:len(prefix)] == prefix })
				changed = true
			}
		}
		s.calls = slices.Clone(event.Calls)
		return changed, nil
	case "sms":
		if event.Storage < 0 || event.Storage > 1 || len(event.PDUs) > 128 {
			return false, errors.New("invalid SMS snapshot")
		}
		ids := make([]string, 0, len(event.PDUs))
		details := make(map[string]string)
		parts := make(map[string]smsPart)
		for _, raw := range event.PDUs {
			pdu, err := hex.DecodeString(raw)
			if err != nil || len(pdu) < 2 || len(pdu) > 512 {
				return false, errors.New("invalid SMS PDU")
			}
			// WMS GW_PP includes the SMSC length octet; only SMS-DELIVER.
			offset := 1 + int(pdu[0])
			if offset >= len(pdu) {
				return false, errors.New("invalid SMSC length")
			}
			if pdu[offset]&3 != 0 {
				continue
			}
			hash := sha256.Sum256(pdu)
			id := hex.EncodeToString(hash[:])
			ids = append(ids, id)
			sender, text, timestamp, concat, decodeErr := smscodec.DecodeDeliverTPDU(pdu[offset:])
			if decodeErr == nil {
				if options.ShowSMSBody {
					details[id] = normalizedDetail(text, 240)
				}
				if concat.IsConcat && concat.Total > 1 && concat.Total <= 255 && concat.Seq >= 1 && concat.Seq <= concat.Total {
					digest := sha256.Sum256([]byte(fmt.Sprintf("%s/%d/%d/%d", sender, concat.RefBits, concat.Ref, concat.Total)))
					parts[id] = smsPart{id: id, key: hex.EncodeToString(digest[:]), text: text, timestamp: timestamp, concat: concat}
				}
			}
		}
		slices.Sort(ids)
		ids = slices.Compact(ids)
		previous, initialized := s.SMS[event.Storage]
		changed := !initialized || !slices.Equal(previous, ids)
		for _, id := range ids {
			fresh := initialized && !slices.Contains(previous, id) && !slices.Contains(s.SMS[1-event.Storage], id)
			if part, ok := parts[id]; ok {
				if s.addSMSPart(part, fresh, options, now) {
					changed = true
				}
			} else if fresh {
				s.enqueue("sms", "sms-"+id, options.Transports, details[id], now)
			}
		}
		if s.SMS == nil {
			s.SMS = make(map[int][]string)
		}
		s.SMS[event.Storage] = ids
		return changed, nil
	default:
		return false, errors.New("unknown snapshot kind")
	}
}

func (s *State) addSMSPart(part smsPart, fresh bool, options EventOptions, now time.Time) bool {
	var group *multipartSMS
	var groupID string
	for id, candidate := range s.Multipart {
		if candidate.Key != part.key || !now.Before(candidate.Expires) {
			continue
		}
		if !candidate.Timestamp.IsZero() && !part.timestamp.IsZero() && candidate.Timestamp.Sub(part.timestamp).Abs() > 10*time.Minute {
			continue
		}
		if old, ok := candidate.IDs[part.concat.Seq]; ok && old != part.id {
			continue
		}
		// Ambiguous reference reuse must not join two different messages.
		if group != nil {
			return false
		}
		group, groupID = candidate, id
	}
	if group == nil {
		if s.Multipart == nil {
			s.Multipart = make(map[string]*multipartSMS)
		}
		if len(s.Multipart) >= 128 {
			var oldest string
			for id, candidate := range s.Multipart {
				if oldest == "" || candidate.Expires.Before(s.Multipart[oldest].Expires) {
					oldest = id
				}
			}
			delete(s.Multipart, oldest)
		}
		groupID = "sms-multipart-" + part.id
		group = &multipartSMS{Key: part.key, Timestamp: part.timestamp, Expires: now.Add(24 * time.Hour), Total: part.concat.Total,
			IDs: make(map[int]string), Text: make(map[int]string), Silent: !fresh}
		s.Multipart[groupID] = group
	}
	if _, exists := group.IDs[part.concat.Seq]; exists {
		return false
	}
	if !fresh {
		group.Silent = true
		group.Text = nil
	}
	group.IDs[part.concat.Seq] = part.id
	if options.ShowSMSBody && !group.Silent && !group.Notified {
		if group.Text == nil {
			group.Text = make(map[int]string)
		}
		group.Text[part.concat.Seq] = part.text
	}
	if len(group.IDs) == group.Total && !group.Silent && !group.Notified {
		var body strings.Builder
		if options.ShowSMSBody && len(group.Text) == group.Total {
			for sequence := 1; sequence <= group.Total; sequence++ {
				body.WriteString(group.Text[sequence])
			}
		}
		s.enqueue("sms", groupID, options.Transports, normalizedDetail(body.String(), 240), now)
		group.Notified = true
		group.Text = nil
	}
	return true
}

func (s *State) enqueue(kind, key string, transports []string, detail string, now time.Time) {
	ttl := 24 * time.Hour
	if kind == "call" {
		ttl = 25 * time.Second
	}
	s.Sequence++
	for _, transport := range transports {
		if kind == "sms" && slices.ContainsFunc(s.Queue, func(d Delivery) bool { return d.Transport == transport && d.ID == key }) {
			continue
		}
		id := key
		if kind == "call" {
			id = fmt.Sprintf("%s/%d", key, s.Sequence)
		}
		// Bound disk usage during a prolonged outage. Prefer live calls over SMS.
		if len(s.Queue) >= 256 {
			index := slices.IndexFunc(s.Queue, func(d Delivery) bool { return d.Kind == "sms" })
			if index < 0 {
				index = 0
			}
			s.Queue = slices.Delete(s.Queue, index, index+1)
		}
		s.Queue = append(s.Queue, Delivery{ID: id, Kind: kind, Transport: transport, Expires: now.Add(ttl), Next: now, Detail: detail})
	}
}

func normalizedDetail(value string, maxRunes int) string {
	value = strings.Map(func(r rune) rune {
		if unicode.IsControl(r) && r != '\n' && r != '\t' {
			return ' '
		}
		return r
	}, strings.ToValidUTF8(value, ""))
	value = strings.Join(strings.Fields(value), " ")
	runes := []rune(value)
	if len(runes) > maxRunes {
		value = string(runes[:maxRunes]) + "…"
	}
	return value
}

func normalizedCallNumber(value string) string {
	if value == "" || len(value) > 81 {
		return ""
	}
	for index, r := range value {
		if (r >= '0' && r <= '9') || r == '*' || r == '#' || (r == '+' && index == 0 && len(value) > 1) {
			continue
		}
		return ""
	}
	return value
}

// RedactQueuedDetails immediately applies a stricter privacy choice to
// notifications that were waiting for retry when the daemon restarted.
func (s *State) RedactQueuedDetails(showCallNumber, showSMSBody bool) bool {
	changed := false
	if !showSMSBody {
		for _, group := range s.Multipart {
			if len(group.Text) > 0 {
				group.Text = nil
				changed = true
			}
		}
	}
	for index := range s.Queue {
		keep := (s.Queue[index].Kind == "call" && showCallNumber) ||
			(s.Queue[index].Kind == "sms" && showSMSBody)
		if !keep && s.Queue[index].Detail != "" {
			s.Queue[index].Detail = ""
			changed = true
		}
	}
	return changed
}

func (s *State) Reconcile(options EventOptions) bool {
	changed := s.RedactQueuedDetails(options.ShowCallNumber, options.ShowSMSBody)
	before := len(s.Queue)
	s.Queue = slices.DeleteFunc(s.Queue, func(delivery Delivery) bool {
		return !slices.Contains(options.Transports, delivery.Transport)
	})
	return changed || len(s.Queue) != before
}

// Finish returns false when an in-flight call was already cancelled.
func (s *State) Finish(id, transport string, retry bool, now time.Time) bool {
	index := slices.IndexFunc(s.Queue, func(d Delivery) bool { return d.ID == id && d.Transport == transport })
	if index < 0 {
		return false
	}
	d := &s.Queue[index]
	d.Attempts++
	if !retry || !now.Before(d.Expires) || d.Attempts >= 10 {
		s.Queue = slices.Delete(s.Queue, index, index+1)
	} else {
		delay := time.Second * time.Duration(1<<min(d.Attempts, 8))
		d.Next = now.Add(delay)
	}
	return true
}

func (s *State) Expire(now time.Time) bool {
	changed := false
	for id, group := range s.Multipart {
		if !now.Before(group.Expires) {
			delete(s.Multipart, id)
			changed = true
		}
	}
	before := len(s.Queue)
	s.Queue = slices.DeleteFunc(s.Queue, func(d Delivery) bool { return !now.Before(d.Expires) })
	return changed || len(s.Queue) != before
}
