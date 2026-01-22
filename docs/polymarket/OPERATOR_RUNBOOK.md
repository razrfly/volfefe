# Polymarket Insider Detection - Operator Runbook

## Overview

This runbook provides operational guidance for running and maintaining the Polymarket insider trading detection system. The system monitors trades in real-time, scores them against learned insider patterns, and generates alerts for suspicious activity.

---

## System Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         DATA INGESTION                                   │
├─────────────────────────────────────────────────────────────────────────┤
│  TradeIngestionWorker (every 5 min) → Trades → TradeScore → Alerts      │
│  MarketSyncWorker (hourly) → Markets, Resolutions                       │
│  DiversityCheckWorker (every 30 min) → Coverage Health                  │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                         REAL-TIME MONITORING                             │
├─────────────────────────────────────────────────────────────────────────┤
│  TradeMonitor (GenServer) → Score → Pattern Match → Alert Generation    │
│  Poll Interval: 30 seconds                                              │
│  Thresholds: anomaly >= 0.7 OR insider_probability >= 0.5               │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                         ALERT PIPELINE                                   │
├─────────────────────────────────────────────────────────────────────────┤
│  Alert Created → PubSub Broadcast → LiveView Update → Notifications     │
│  Channels: Slack (high+), Discord (medium+), Dashboard (all)            │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Quick Reference Commands

### System Status
```bash
# Overall system health
mix polymarket.health

# Monitor status
mix polymarket.monitor

# Alert summary
mix polymarket.alerts

# Notification status
mix polymarket.notify
```

### Real-Time Monitoring
```bash
# Enable monitoring
mix polymarket.monitor --enable

# Disable monitoring
mix polymarket.monitor --disable

# Trigger immediate poll
mix polymarket.monitor --poll

# Watch live alerts
mix polymarket.monitor --watch
```

### Alert Management
```bash
# List all alerts
mix polymarket.alerts

# Filter by status
mix polymarket.alerts --status new
mix polymarket.alerts --status acknowledged
mix polymarket.alerts --status confirmed

# Filter by severity
mix polymarket.alerts --severity critical
mix polymarket.alerts --severity high

# Acknowledge an alert
mix polymarket.alerts --ack ID

# Confirm insider
mix polymarket.confirm --id ALERT_ID
```

### Notifications
```bash
# Test Slack webhook
mix polymarket.notify --test slack

# Test Discord webhook
mix polymarket.notify --test discord

# Test all channels
mix polymarket.notify --test all

# Send notification for specific alert
mix polymarket.notify --alert ID
```

---

## Daily Operations

### Morning Checklist

1. **Check System Health**
   ```bash
   mix polymarket.health
   ```
   - Verify all workers are running
   - Check database connectivity
   - Review error counts

2. **Review Overnight Alerts**
   ```bash
   mix polymarket.alerts --status new --since 24h
   ```
   - Prioritize critical/high severity
   - Check for patterns (same wallet, market)

3. **Check Coverage Health**
   ```bash
   mix polymarket.coverage
   ```
   - Verify category diversity
   - Check for stale markets
   - Review ingestion gaps

4. **Monitor Baseline Quality**
   ```bash
   mix polymarket.baselines
   ```
   - Check separation scores
   - Verify insider data coverage

### Alert Triage Process

#### Severity Levels

| Severity | Response Time | Action Required |
|----------|---------------|-----------------|
| Critical | < 1 hour | Immediate investigation, potential escalation |
| High | < 4 hours | Same-day investigation |
| Medium | < 24 hours | Review within 24 hours |
| Low | < 72 hours | Batch review weekly |

#### Triage Workflow

1. **Initial Assessment** (2-3 minutes)
   - Review alert details in dashboard
   - Check wallet history
   - Note market context

2. **Pattern Analysis** (5-10 minutes)
   - Run `mix polymarket.insiders --wallet ADDRESS`
   - Check cross-market activity
   - Review timing relative to resolution

3. **Decision**
   - **Confirm**: Strong evidence of insider trading
   - **Dismiss**: False positive with clear explanation
   - **Investigate**: Need more data, mark for follow-up

4. **Documentation**
   - Add notes in dashboard
   - Update alert status
   - If confirmed, run feedback loop

### Weekly Tasks

1. **Feedback Loop Update**
   ```bash
   mix polymarket.feedback
   ```
   - Run after confirming new insiders
   - Updates baselines with new patterns

2. **Coverage Review**
   ```bash
   mix polymarket.coverage --detailed
   ```
   - Check category balance
   - Identify underrepresented markets

3. **Performance Review**
   - Review alert accuracy
   - Check false positive rate
   - Adjust thresholds if needed

---

## Alert Investigation Guide

### High-Confidence Signals

These patterns strongly indicate insider trading:

1. **Pre-Resolution Timing** (weight: high)
   - Trade occurs within hours of resolution
   - Timing z-score > 2.5
   - Resolution outcome matches trade direction

2. **Abnormal Size** (weight: high)
   - Trade size > 10x baseline for market
   - Size z-score > 3.0
   - Especially significant for illiquid markets

3. **Perfect Timing + Large Size** (weight: very high)
   - Combination of above signals
   - Insider probability > 0.8

4. **Pattern Match: Known Insider** (weight: very high)
   - Wallet matches confirmed insider patterns
   - Cross-market suspicious activity

### Medium-Confidence Signals

Require additional investigation:

1. **Single Large Trade**
   - Could be whale, institutional, or informed
   - Check wallet history for context

2. **Timing-Only Signal**
   - Market timing alone may be coincidental
   - Look for corroborating evidence

3. **First-Time Wallet**
   - No history to compare
   - May be new insider or legitimate new user

### Low-Confidence / False Positive Patterns

Common false positives:

1. **Market Makers**
   - Regular trading patterns
   - Both buy and sell activity
   - Consistent sizes

2. **Arbitrageurs**
   - Cross-market activity
   - Small margins
   - High frequency

3. **News Traders**
   - Trades after public information
   - Check news timestamps

---

## Incident Response

### P1: System Down

**Symptoms**: No new trades ingested, workers failing, database errors

**Immediate Actions**:
1. Check Phoenix server status
2. Verify database connectivity
3. Check Oban queue health
4. Review error logs

**Recovery**:
```bash
# Restart workers
mix polymarket.ingest --restart

# Check queue status
mix polymarket.health --detailed

# Backfill if needed
mix polymarket.ingest --since "2 hours ago"
```

### P2: High Alert Volume

**Symptoms**: Sudden spike in alerts, potential false positive surge

**Immediate Actions**:
1. Check for external events (market news)
2. Review baseline health
3. Consider temporarily raising thresholds

**Mitigation**:
```bash
# Adjust thresholds temporarily
mix polymarket.monitor --anomaly 0.85 --probability 0.65

# Review affected markets
mix polymarket.alerts --market CONDITION_ID
```

### P3: Notification Failures

**Symptoms**: Webhooks failing, no Slack/Discord notifications

**Immediate Actions**:
1. Test webhook connectivity
2. Check webhook URL validity
3. Verify rate limits not exceeded

**Recovery**:
```bash
# Test webhooks
mix polymarket.notify --test all

# Check configuration
mix polymarket.notify

# Re-send failed notifications
mix polymarket.notify --alert ID
```

---

## Configuration Reference

### Environment Variables

```bash
# Required for notifications
export SLACK_WEBHOOK_URL="https://hooks.slack.com/services/..."
export DISCORD_WEBHOOK_URL="https://discord.com/api/webhooks/..."

# Polymarket API (if using direct API access)
export POLYMARKET_API_KEY="..."
```

### Application Configuration

Location: `config/config.exs` and `config/runtime.exs`

```elixir
# Trade Monitor settings
config :volfefe_machine, VolfefeMachine.Polymarket.TradeMonitor,
  poll_interval: 30_000,        # 30 seconds
  anomaly_threshold: 0.7,       # Min anomaly score to alert
  probability_threshold: 0.5,   # Min insider probability
  enabled: true                 # Enable/disable monitoring

# Notifier settings
config :volfefe_machine, VolfefeMachine.Polymarket.Notifier,
  enabled: true,
  channels: [
    slack: [
      webhook_url: System.get_env("SLACK_WEBHOOK_URL"),
      min_severity: "high"
    ],
    discord: [
      webhook_url: System.get_env("DISCORD_WEBHOOK_URL"),
      min_severity: "medium"
    ]
  ]
```

### Oban Cron Jobs

```elixir
# Trade ingestion every 5 minutes
{"*/5 * * * *", VolfefeMachine.Workers.Polymarket.TradeIngestionWorker}

# Market sync hourly
{"0 * * * *", VolfefeMachine.Workers.Polymarket.MarketSyncWorker}

# Diversity check every 30 minutes
{"*/30 * * * *", VolfefeMachine.Workers.Polymarket.DiversityCheckWorker}
```

---

## Threshold Tuning Guide

### When to Adjust Thresholds

**Lower thresholds** (more sensitive) when:
- False negative rate too high
- Missing known insider activity
- Higher priority on detection

**Raise thresholds** (less sensitive) when:
- False positive rate too high
- Alert fatigue occurring
- Higher priority on precision

### Recommended Threshold Ranges

| Metric | Conservative | Balanced | Aggressive |
|--------|--------------|----------|------------|
| Anomaly Score | 0.85 | 0.70 | 0.55 |
| Insider Probability | 0.65 | 0.50 | 0.35 |
| Size Z-Score | 4.0 | 3.0 | 2.0 |
| Timing Z-Score | 3.0 | 2.5 | 2.0 |

### Adjusting at Runtime

```bash
# Temporary adjustment (session only)
mix polymarket.monitor --anomaly 0.8 --probability 0.6

# Permanent adjustment
# Edit config/runtime.exs and restart
```

---

## Dashboard Guide

### Accessing the Dashboard

URL: `http://localhost:4002/admin/polymarket`

### Tabs Overview

1. **Overview**: Key metrics, recent activity, quick stats
2. **Alerts**: Alert management, triage, acknowledgment
3. **Markets**: Market list, resolution status, coverage
4. **Wallets**: Wallet investigation, history, patterns
5. **Patterns**: Confirmed insider patterns, baselines

### Alert Actions

- **View Details**: Full alert information
- **Investigate Wallet**: Deep dive into wallet activity
- **Acknowledge**: Mark as reviewed
- **Confirm Insider**: Mark wallet as confirmed insider
- **Dismiss**: Mark as false positive with reason

---

## Troubleshooting

### Common Issues

#### "No baselines found"
```bash
# Generate baselines
mix polymarket.baselines --generate

# Or run feedback loop
mix polymarket.feedback
```

#### "Trade scoring failed"
- Check market has baseline data
- Verify trade has required fields
- Run `mix polymarket.feedback` to update baselines

#### "Notification not received"
1. Check webhook URL is correct
2. Test with `mix polymarket.notify --test slack`
3. Verify severity meets minimum threshold
4. Check application logs for errors

#### "High error count in health check"
- Review application logs
- Check database connectivity
- Verify API access
- Check for rate limiting

### Log Locations

```bash
# Application logs
tail -f log/dev.log

# Oban job logs (in database)
# View via dashboard or direct query
```

---

## Escalation Contacts

| Severity | Primary Contact | Escalation |
|----------|-----------------|------------|
| Critical | On-call engineer | Engineering lead |
| High | Assigned analyst | Team lead |
| Medium | Alert queue | Daily triage |
| Low | Weekly review | N/A |

---

## Glossary

- **Anomaly Score**: Composite score (0-1) indicating how unusual a trade is
- **Baseline**: Statistical model of normal trading behavior for a market
- **Condition ID**: Unique identifier for a market outcome
- **Insider Probability**: Estimated probability (0-1) that trade is by insider
- **Resolution**: When a market outcome is determined
- **Separation Score**: How well baseline distinguishes insiders from normal traders
- **Z-Score**: Number of standard deviations from mean (higher = more unusual)

---

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2025-01-22 | Initial runbook |
