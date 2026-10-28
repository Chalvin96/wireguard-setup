# Discord notifications

Grafana uses the `homelab-discord` notification template for concise titles and
messages. Messages show the node, severity, alert summary, a readable measurement
when available, and one suggested action. Recovery messages identify the cleared
alert without repeating old measurements or troubleshooting steps.

Raw labels, internal addresses, expression values and silence URLs are omitted
from message text. Routing, reminder intervals and recovery delivery are unchanged.
The existing Discord integration supplies its standard Grafana link and footer.

Deploy notification formatting without restarting the monitoring stack:

```bash
ansible-playbook ansible/notifications.yml --vault-password-file .vault_password
```

Grafana's template-preview API can validate firing and resolved samples without
sending a message to Discord. Measurements are alert annotations so the same
readable values are available in Grafana's alert state.
