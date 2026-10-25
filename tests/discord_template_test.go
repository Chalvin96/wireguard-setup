package notifications

import (
	"bytes"
	"os"
	"strings"
	"testing"
	"text/template"
)

type notificationAlert struct {
	Status      string
	Labels      map[string]string
	Annotations map[string]string
}

type notificationData struct {
	Status       string
	CommonLabels map[string]string
	Alerts       []notificationAlert
}

func TestDiscordMessages(t *testing.T) {
	source, err := os.ReadFile(os.Getenv("DISCORD_TEMPLATE_FILE"))
	if err != nil {
		t.Fatal(err)
	}
	parsed, err := template.New("notifications").Parse(string(source))
	if err != nil {
		t.Fatal(err)
	}
	cases := []struct {
		name, status, service, host, severity, summary, title string
	}{
		{"warning", "firing", "sindri", "tools-01", "warning", "Sindri disk usage high", "⚠ Warning · Sindri"},
		{"critical", "firing", "proxmox", "proxmox", "critical", "Proxmox storage low", "🚨 Critical · Proxmox"},
		{"resolved", "resolved", "sindri", "tools-01", "warning", "Sindri disk usage high", "✅ Resolved · Sindri"},
		{"monitoring", "firing", "", "monitoring-01", "warning", "Monitoring storage low", "⚠ Warning · Hlidskjalf"},
		{"missing-summary", "firing", "", "192.0.2.40", "", "", "⚠ Warning · Homelab"},
	}
	for _, item := range cases {
		t.Run(item.name, func(t *testing.T) {
			alert := notificationAlert{
				Status: item.status,
				Labels: map[string]string{"alertname": "DatasourceNoData", "instance": "192.0.2.40:9100", "device": "/dev/example"},
				Annotations: map[string]string{
					"summary": item.summary, "measurement": "Used: 94.0 GB (warning above 90 GB).",
					"description": "Check cleanup status.",
				},
			}
			data := notificationData{item.status, map[string]string{"service": item.service, "host": item.host, "severity": item.severity}, []notificationAlert{alert}}
			var title, message bytes.Buffer
			if err := parsed.ExecuteTemplate(&title, "homelab.discord.title", data); err != nil {
				t.Fatal(err)
			}
			if title.String() != item.title {
				t.Fatalf("title = %q, want %q", title.String(), item.title)
			}
			if err := parsed.ExecuteTemplate(&message, "homelab.discord.message", data); err != nil {
				t.Fatal(err)
			}
			for _, forbidden := range []string{"192.0.2.40", "/dev/example", "Value:", "Labels:", "http://", "A=", "B=", "C="} {
				if strings.Contains(title.String()+message.String(), forbidden) {
					t.Fatalf("notification contains %q", forbidden)
				}
			}
			if item.status == "resolved" {
				if !strings.Contains(message.String(), "Cleared:") || strings.Contains(message.String(), "Next:") || strings.Contains(message.String(), "94.0") {
					t.Fatalf("unexpected recovery: %q", message.String())
				}
			} else if !strings.Contains(message.String(), "94.0 GB") || !strings.Contains(message.String(), "Next: Check cleanup status.") {
				t.Fatalf("missing measurement or action: %q", message.String())
			}
			if item.summary == "" && !strings.Contains(message.String(), "DatasourceNoData") {
				t.Fatal("missing fallback alert name")
			}
		})
	}
}
