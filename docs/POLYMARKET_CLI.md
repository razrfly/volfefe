# Polymarket Insider Detection CLI

Command-line interface for the Polymarket Insider Detection System. All dashboard functionality accessible via mix tasks for testing and iteration.

## System Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                     DETECTION WORKFLOW                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Confirmed Insiders → calculate_insider_baselines()            │
│                              ↓                                  │
│                    Insider Behavior Profile                     │
│                              ↓                                  │
│                    rescore_all_trades()                         │
│                              ↓                                  │
│                    All Trades Get Scored                        │
│                              ↓                                  │
│                    run_discovery()                              │
│                              ↓                                  │
│                    NEW Unknown Candidates                       │
│                              ↓                                  │
│                    Investigation & Confirmation                 │
│                              ↓                                  │
│                         LOOP REPEATS                            │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

## Quick Start

```bash
# Check system status
mix polymarket.status

# Run discovery to find candidates
mix polymarket.discover --limit 50

# List candidates for investigation
mix polymarket.candidates

# Investigate a candidate
mix polymarket.candidate --id 1
mix polymarket.investigate --id 1 --start

# Confirm as insider (improves future detection)
mix polymarket.confirm --id 1 --confidence confirmed

# Run feedback loop to learn from confirmations
mix polymarket.feedback
```

---

## Mix Tasks Reference

### Status & Overview

#### `mix polymarket.status`
Display system dashboard statistics.

```bash
# Full dashboard overview
mix polymarket.status

# Investigation-focused stats
mix polymarket.status --investigation

# Feedback loop metrics
mix polymarket.status --feedback

# All stats in one view
mix polymarket.status --all
```

**Output includes:**
- Total trades, markets, wallets
- Alert counts by severity
- Candidate counts by status
- Pattern performance metrics
- Baseline separation scores

---

### Listing Operations

#### `mix polymarket.alerts`
List system alerts.

```bash
# All alerts (default limit 50)
mix polymarket.alerts

# Filter by status
mix polymarket.alerts --status new
mix polymarket.alerts --status investigating

# Filter by severity
mix polymarket.alerts --severity critical
mix polymarket.alerts --severity high

# Combine filters
mix polymarket.alerts --status new --severity critical --limit 10
```

#### `mix polymarket.candidates`
List investigation candidates.

```bash
# All candidates
mix polymarket.candidates

# Filter by status
mix polymarket.candidates --status undiscovered
mix polymarket.candidates --status investigating

# Filter by priority
mix polymarket.candidates --priority critical

# Custom limit
mix polymarket.candidates --limit 100
```

#### `mix polymarket.patterns`
List insider patterns with performance metrics.

```bash
# All patterns with stats
mix polymarket.patterns

# Active patterns only
mix polymarket.patterns --active

# Show detailed conditions
mix polymarket.patterns --verbose
```

#### `mix polymarket.batches`
List discovery batch history.

```bash
# Recent batches
mix polymarket.batches

# With limit
mix polymarket.batches --limit 20
```

---

### Investigation Workflow

#### `mix polymarket.candidate`
View detailed information about a single candidate.

```bash
# View candidate details
mix polymarket.candidate --id 1

# Include wallet profile
mix polymarket.candidate --id 1 --profile

# Include similar candidates
mix polymarket.candidate --id 1 --similar
```

**Output includes:**
- Trade context (size, timing, outcome)
- Anomaly score breakdown
- Pattern matches
- Wallet profile
- Risk assessment

#### `mix polymarket.investigate`
Manage investigation workflow.

```bash
# Start investigation
mix polymarket.investigate --id 1 --start

# Add investigation note
mix polymarket.investigate --id 1 --note "Researched wallet history, suspicious pattern"

# Resolve as confirmed insider
mix polymarket.investigate --id 1 --resolve confirmed_insider

# Resolve as cleared (not insider)
mix polymarket.investigate --id 1 --resolve cleared

# Dismiss candidate
mix polymarket.investigate --id 1 --dismiss --reason "Insufficient evidence"
```

**Resolution options:**
- `confirmed_insider` - Confirmed as insider trading
- `cleared` - Investigated and cleared
- `escalated` - Needs further review
- `inconclusive` - Unable to determine

#### `mix polymarket.confirm`
Confirm a candidate as an insider (creates ConfirmedInsider record).

```bash
# Confirm with defaults
mix polymarket.confirm --id 1

# Specify confidence level
mix polymarket.confirm --id 1 --confidence confirmed
mix polymarket.confirm --id 1 --confidence likely
mix polymarket.confirm --id 1 --confidence suspected

# With evidence
mix polymarket.confirm --id 1 --confidence confirmed --source news_report --notes "Article link: ..."

# Run mini feedback loop after confirmation
mix polymarket.confirm --id 1 --run-feedback
```

---

### Discovery & Feedback

#### `mix polymarket.discover`
Run discovery to find new investigation candidates.

```bash
# Quick discovery with defaults
mix polymarket.discover

# Custom limit
mix polymarket.discover --limit 100

# Custom thresholds
mix polymarket.discover --anomaly 0.6 --probability 0.5

# Full options
mix polymarket.discover --limit 50 --anomaly 0.5 --probability 0.4 --min-profit 100

# Dry run (show what would be found)
mix polymarket.discover --dry-run
```

**Parameters:**
- `--limit` - Maximum candidates to generate (default: 100)
- `--anomaly` - Minimum anomaly score threshold (default: 0.5)
- `--probability` - Minimum insider probability threshold (default: 0.4)
- `--min-profit` - Minimum profit filter (default: 100)

#### `mix polymarket.feedback`
Run the full feedback loop iteration.

```bash
# Run feedback loop with defaults
mix polymarket.feedback

# Skip rescoring (faster)
mix polymarket.feedback --no-rescore

# Custom discovery limit
mix polymarket.feedback --discovery-limit 50

# With notes
mix polymarket.feedback --notes "Iteration after 3 new confirmations"

# Verbose output
mix polymarket.feedback --verbose
```

**Feedback loop steps:**
1. Mark confirmed insiders for training
2. Recalculate insider baselines
3. Re-validate pattern performance
4. Rescore all trades (optional)
5. Run discovery with updated scores

#### `mix polymarket.export`
Export data to CSV files.

```bash
# Export candidates
mix polymarket.export --candidates
mix polymarket.export --candidates --file ./exports/candidates.csv

# Export confirmed insiders
mix polymarket.export --insiders

# Export alerts
mix polymarket.export --alerts

# Export pattern matches
mix polymarket.export --patterns
```

---

### Maintenance Operations

#### `mix polymarket.baselines`
Recalculate insider baselines from confirmed insiders.

```bash
# Recalculate all baselines
mix polymarket.baselines

# Verbose output
mix polymarket.baselines --verbose
```

#### `mix polymarket.rescore`
Rescore all trades with current baselines.

```bash
# Rescore all trades
mix polymarket.rescore

# Rescore with limit (for testing)
mix polymarket.rescore --limit 1000

# Force recalculation
mix polymarket.rescore --force
```

#### `mix polymarket.validate`
Validate pattern performance against current data.

```bash
# Validate all patterns
mix polymarket.validate

# Validate specific pattern
mix polymarket.validate --pattern whale_correct
```

#### `mix polymarket.recommend`
Get AI recommendations for next actions.

```bash
# Get recommendations
mix polymarket.recommend
```

**Recommends actions like:**
- Run feedback loop if untrained insiders exist
- Investigate critical priority candidates
- Run discovery if queue is low
- Add patterns if F1 scores are low

---

## Common Workflows

### Initial Setup Testing

```bash
# 1. Check system status
mix polymarket.status

# 2. Verify data is loaded
mix polymarket.status --all

# 3. Check existing candidates
mix polymarket.candidates

# 4. Check patterns are defined
mix polymarket.patterns
```

### Daily Investigation Workflow

```bash
# 1. Check for new alerts
mix polymarket.alerts --status new

# 2. Review candidate queue
mix polymarket.candidates --status undiscovered --priority critical

# 3. Investigate top candidate
mix polymarket.candidate --id 1 --profile
mix polymarket.investigate --id 1 --start

# 4. After research, resolve
mix polymarket.investigate --id 1 --resolve confirmed_insider
# OR
mix polymarket.investigate --id 1 --resolve cleared

# 5. Confirm if insider
mix polymarket.confirm --id 1 --confidence confirmed --source investigation
```

### Feedback Loop Iteration

```bash
# 1. Check pre-loop stats
mix polymarket.status --feedback

# 2. Run feedback loop
mix polymarket.feedback --verbose

# 3. Check post-loop stats
mix polymarket.status --feedback

# 4. Review new candidates
mix polymarket.candidates --status undiscovered

# 5. Get recommendations
mix polymarket.recommend
```

### Prediction Testing

```bash
# 1. Get baseline stats
mix polymarket.status --feedback

# 2. Run discovery
mix polymarket.discover --limit 50

# 3. Check candidates found
mix polymarket.candidates --status undiscovered

# 4. Investigate and confirm some
mix polymarket.confirm --id X --confidence likely

# 5. Run feedback loop
mix polymarket.feedback

# 6. Run discovery again
mix polymarket.discover --limit 50

# 7. Compare candidate counts (should increase)
mix polymarket.status
```

---

## Environment Variables

```bash
# Database (required)
DATABASE_URL=postgres://...

# Optional: Verbose logging
POLYMARKET_DEBUG=true
```

---

## Related Documentation

- **UI Dashboard**: `/admin/polymarket`
- **Issue #100**: Original architecture
- **Issue #104**: Dashboard implementation
- **Issue #105**: Prediction testing protocol
- **Issue #106**: This CLI implementation

---

## Troubleshooting

### No candidates found
```bash
# Check if trades are scored
mix polymarket.status

# Lower thresholds
mix polymarket.discover --anomaly 0.3 --probability 0.2
```

### Feedback loop shows no improvement
```bash
# Check confirmed insiders
mix polymarket.status --feedback

# Need at least 3 confirmed insiders for meaningful baselines
```

### Baselines not updating
```bash
# Check if insiders have linked trades
mix polymarket.status --feedback

# Manually recalculate
mix polymarket.baselines --verbose
```
