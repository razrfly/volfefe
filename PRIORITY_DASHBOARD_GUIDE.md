# Market Data Priority Dashboard - User Guide

## What's New?

Your Market Data Dashboard (`/admin/market-data`) now shows **priority tiers** for all content missing snapshots, helping you identify which content to capture first to maximize API credit efficiency.

## How to Use

### 1. Navigate to Dashboard

Visit: `http://localhost:4002/admin/market-data`

### 2. View Priority Breakdown

Click the **"🎯 View Priority Breakdown"** button to expand the priority analysis panel.

You'll see:
- **Tier Distribution Cards**: Quick overview of how many items are in each tier
- **Filter Buttons**: Click to filter by specific tiers
- **Content Table**: Detailed list with priority badges

### 3. Understand the Tiers

#### 🥇 Tier 1: HIGHEST PRIORITY
- **Published during market hours** (9:30 AM - 4:00 PM ET, Mon-Fri)
- **Mentions tracked assets** (has content_targets)
- **Strong sentiment** (positive/negative with ≥80% confidence)

**Why prioritize**: Maximum chance of valid market data + asset-specific analysis

---

#### 🥈 Tier 2: MEDIUM PRIORITY
- **Published during market hours**
- **Strong sentiment** (≥80% confidence)
- **Multiple entity mentions** (≥2 organizations mentioned)

**Why prioritize**: Good market commentary with strong signal quality

---

#### 🥉 Tier 3: LOWER PRIORITY
- **Has content_targets** (mentions tracked assets)
- **Posted outside market hours** (but not weekends)

**Why prioritize**: Still captures 24hr_after next-day market reaction

---

#### ❌ SKIP (Save Credits)
- Neutral sentiment with low confidence (<70%)
- No asset mentions
- Weekend posts (no next trading day)

**Why skip**: Low probability of meaningful market correlation

---

## Workflow Example

### Step 1: Expand Priority Breakdown
```
Click "🎯 View Priority Breakdown"
```

You'll see something like:
```
🥇 Tier 1: 12 items
🥈 Tier 2: 23 items
🥉 Tier 3: 45 items
❌ Skip: 18 items
```

### Step 2: Filter to Tier 1
```
Click "🥇 Tier 1 (12)" button
```

Now you see only the 12 highest-priority items to capture.

### Step 3: Capture Snapshots
```
1. Set dropdown to "Missing Snapshots Only"
2. Check API cost estimate
3. Click "📸 Enqueue Market Data Jobs"
```

**Note**: The system will capture ALL missing snapshots (all tiers). To capture only Tier 1:
1. Note the Content IDs from the filtered table
2. Select "Specific IDs" in dropdown
3. Enter comma-separated IDs: `234,235,236`
4. Click "📸 Enqueue Market Data Jobs"

---

## Understanding the Table Columns

| Column | Description |
|--------|-------------|
| **ID** | Content ID number |
| **Priority** | Tier badge with color coding |
| **Published** | When content was posted (MM/DD HH:MM) |
| **Sentiment** | Classification result (sentiment + confidence %) |
| **Targets** | Number of tracked assets mentioned |
| **Text Preview** | First 100 characters of content |

---

## Tips for Credit Optimization

### Phase 1: Start with Tier 1 Only
1. Filter to Tier 1
2. Note the IDs
3. Capture only those IDs
4. **Expected result**: 40-60% valid data rate (vs. 3% before)

### Phase 2: Expand to Tier 2
1. Once Tier 1 is complete
2. Expand to Tier 2 content
3. **Expected result**: 60-80% valid data rate

### Phase 3: Fill in Tier 3
1. After Tiers 1 & 2
2. Capture Tier 3 for 24hr_after data
3. **Expected result**: Comprehensive coverage with 70%+ valid data

### Always Skip
- ❌ Skip tier items waste credits
- Save these for when you have unlimited credits

---

## What the Priority Logic Checks

The system evaluates each piece of content based on:

1. **Timing** (`published_at`):
   - Market hours detection (9:30 AM - 4:00 PM ET)
   - Weekend detection

2. **Asset Targeting** (`content_targets` table):
   - Does it mention tracked assets (SPY, QQQ, DIA, etc.)?
   - From NER entity extraction

3. **Sentiment Strength** (`classifications` table):
   - Sentiment type (positive, negative, neutral)
   - Confidence score (0.0 - 1.0)

4. **Entity Density** (`classification.meta["entities"]`):
   - How many organizations mentioned?
   - More entities = broader market commentary

---

## Code Reference

**Priority Logic**: `lib/volfefe_machine/market_data/priority.ex`

**Dashboard**:
- LiveView: `lib/volfefe_machine_web/live/admin/market_data_dashboard_live.ex`
- Template: `lib/volfefe_machine_web/live/admin/market_data_dashboard_live.html.heex`

**Key Functions**:
```elixir
# Evaluate content priority
Priority.evaluate(content)
# Returns: {:eligible, 1|2|3} or {:skip, reason}

# Get tier labels
Priority.tier_label(1)  # "🥇 Tier 1: Highest"

# Get tier descriptions
Priority.tier_description(1)  # "Market hours + asset targets + strong sentiment"
```

---

## Future Enhancements (See Issue #90)

- [ ] Auto-capture only Tier 1 & 2 (make skipping automatic)
- [ ] Add "Capture by Tier" button (one-click Tier 1 capture)
- [ ] Add `market_priority` column to database (permanent storage)
- [ ] ML-based "market relevance" classifier (AI predicts impact)
- [ ] Dashboard analytics (track valid data % by tier)

---

## Troubleshooting

### "No items in Tier 1"
**Cause**: No content posted during market hours with asset targets.

**Solution**:
1. Check if you have content published 9:30 AM - 4:00 PM ET
2. Check if NER populated `content_targets` table
3. Try Tier 2 or Tier 3 instead

### "All items showing as Skip"
**Cause**: Content doesn't meet tier criteria.

**Possible reasons**:
- Posted outside market hours (evenings/weekends)
- No asset mentions detected by NER
- Low sentiment confidence (<80%)
- Neutral sentiment

**Solution**: Review criteria in Issue #90 and adjust thresholds if needed.

### "Priority breakdown not loading"
**Cause**: Large dataset causing timeout.

**Solution**:
1. Select "Most Recent 10" or "50" instead of "Missing Snapshots Only"
2. Refresh page
3. Check logs for errors

---

## Questions?

See **GitHub Issue #90** for full prioritization strategy documentation:
https://github.com/razrfly/volfefe/issues/90
