package main

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func TestWants(t *testing.T) {
	now := time.Unix(1000, 0)
	d := Device{Topics: []Topic{{Topic: "a", MinPriority: 4}, {Topic: "b", MinPriority: 1, MutedUntil: 2000}}}
	cases := []struct {
		m    Message
		want bool
	}{
		{Message{Topic: "a", Priority: 5}, true},
		{Message{Topic: "a", Priority: 0}, false}, // 0 means default (3)
		{Message{Topic: "b", Priority: 5}, false}, // muted
		{Message{Topic: "c", Priority: 5}, false},
	}
	for _, c := range cases {
		if got := wants(d, c.m, now); got != c.want {
			t.Errorf("wants(%+v) = %v", c.m, got)
		}
	}
	if !wants(d, Message{Topic: "b", Priority: 3}, time.Unix(2000, 0)) {
		t.Error("mute should expire")
	}
}

func TestPayloadHidesCiphertextAndFits(t *testing.T) {
	m := Message{ID: "x", Topic: "alerts", Title: "🔒 Encrypted message", Message: e2ePrefix + "abc", Priority: 5}
	raw, _ := json.Marshal(m)
	var p struct {
		Aps map[string]any
		S   string
		M   json.RawMessage
	}
	json.Unmarshal(Payload(m, raw, "srv"), &p)
	alert := p.Aps["alert"].(map[string]any)
	if strings.Contains(alert["body"].(string), e2ePrefix) || p.S != "srv" || len(p.M) == 0 {
		t.Fatalf("bad payload %+v", p)
	}
	if p.Aps["interruption-level"] != "time-sensitive" {
		t.Fatal("urgent should be time-sensitive")
	}

	big := Message{ID: "y", Topic: "t", Message: strings.Repeat("é", 3000)}
	raw, _ = json.Marshal(big)
	if out := Payload(big, raw, "srv"); len(out) > 4096 || strings.Contains(string(out), `"m"`) {
		t.Fatalf("oversized payload: %d bytes", len(out))
	}
}
