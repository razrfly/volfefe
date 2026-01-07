# Polymarket API Research Findings

**Date**: 2026-01-06
**Status**: BREAKTHROUGH - Full public access to trade data with wallet addresses

## Executive Summary

We discovered that Polymarket's `data-api.polymarket.com` provides **PUBLIC access** to all trade data including wallet addresses, trading history, and open positions - **NO AUTHENTICATION REQUIRED**.

This is exactly what we need for insider detection.

---

## API Endpoints Discovered

### 1. Trade Data (PUBLIC)

#### All Recent Trades
```bash
curl "https://data-api.polymarket.com/trades?limit=100"
```

#### Trades for Specific Market
```bash
curl "https://data-api.polymarket.com/trades?market={conditionId}&limit=100&offset=0"
```

**Response Fields**:
| Field | Type | Description |
|-------|------|-------------|
| `proxyWallet` | string | Wallet address (KEY FOR INSIDER DETECTION) |
| `side` | string | BUY or SELL |
| `size` | number | Trade size in outcome tokens |
| `price` | number | Execution price (0-1) |
| `timestamp` | number | Unix timestamp |
| `conditionId` | string | Market identifier |
| `title` | string | Market question |
| `outcome` | string | Yes/No outcome traded |
| `transactionHash` | string | Blockchain transaction |
| `name` | string | User's display name |
| `pseudonym` | string | Auto-generated pseudonym |

### 2. Wallet Activity (PUBLIC)

```bash
curl "https://data-api.polymarket.com/activity?user={walletAddress}&limit=100"
```

Returns **ALL trading activity** for a wallet across ALL markets. Perfect for profiling wallets.

**Additional Fields**:
| Field | Type | Description |
|-------|------|-------------|
| `type` | string | TRADE, etc. |
| `usdcSize` | number | USD value of trade |

### 3. Wallet Positions (PUBLIC)

```bash
curl "https://data-api.polymarket.com/positions?user={walletAddress}"
```

Returns current open positions with P&L data.

**Key Fields**:
| Field | Type | Description |
|-------|------|-------------|
| `size` | number | Position size |
| `avgPrice` | number | Average entry price |
| `initialValue` | number | Cost basis |
| `currentValue` | number | Current market value |
| `cashPnl` | number | Unrealized P&L in USD |
| `percentPnl` | number | Unrealized P&L % |
| `realizedPnl` | number | Closed position P&L |
| `curPrice` | number | Current market price |

### 4. Market Discovery (PUBLIC)

```bash
# Active markets sorted by volume
curl "https://gamma-api.polymarket.com/markets?closed=false&active=true&order=volume24hr&ascending=false&limit=100"

# Events with markets
curl "https://gamma-api.polymarket.com/events?closed=false&limit=50"
```

**Key Fields**:
- `conditionId` - Market identifier for trade queries
- `volume24hr`, `volume1wk`, `volume1mo` - Volume metrics
- `liquidity` - Available liquidity
- `outcomePrices` - Current Yes/No prices

---

## Data Access Strategy

### For Insider Detection

1. **Stream Recent Trades**
   - Poll `/trades?limit=100` every N seconds
   - Extract unique wallet addresses from trades

2. **Profile Suspicious Wallets**
   - Query `/activity?user={wallet}` for full history
   - Query `/positions?user={wallet}` for current exposure

3. **Calculate Insider Signals**
   - Trade timing relative to market events
   - Win rate across markets
   - Concentration (single market vs diversified)
   - Position sizing relative to normal distribution

### Pagination

- **Supported**: `limit` and `offset` parameters
- **Tested**: Successfully retrieved trades from offset=1000
- **Rate Limits**: Not hit during testing (needs further investigation)

---

## Comparison with Original Assumptions

| Assumption | Reality |
|------------|---------|
| Need authentication for trades | NO - Public access |
| Wallet addresses hidden | NO - `proxyWallet` exposed |
| Need blockchain scraping | NO - API provides all data |
| Complex CLOB client needed | NO - Simple HTTP requests |

---

## Endpoints NOT Working (or require auth)

- `/leaderboard` - Returns empty
- `/profit-leaderboard` - Returns empty
- `/rankings` - Returns empty
- `/profiles` - Returns error
- `clob.polymarket.com/trades` - Requires authentication

---

## Next Steps

1. **Build Elixir ingestion module** for Polymarket trades
2. **Design insider scoring algorithm** based on available data
3. **Create wallet profiling system**
4. **Set up real-time trade monitoring**

---

## Sample Data

### Trade Example
```json
{
    "proxyWallet": "0xcc74635b8a12d638a1c030637f783e3a9bf7f5aa",
    "side": "BUY",
    "size": 226.474,
    "price": 0.004415517896094033,
    "timestamp": 1767737739,
    "title": "Will 2025 be the hottest year on record?",
    "outcome": "Yes",
    "pseudonym": "Menacing-Prosperity",
    "transactionHash": "0x6f9b9d5998aebd25d6a976ad6251eb6934ec2f5e4dad304646a2c57dcfe9c454"
}
```

### Position Example
```json
{
    "proxyWallet": "0xcc74635b8a12d638a1c030637f783e3a9bf7f5aa",
    "size": 416.5675,
    "avgPrice": 0.024,
    "initialValue": 9.9992,
    "currentValue": 7.4982,
    "cashPnl": -2.501,
    "percentPnl": -25.0117,
    "realizedPnl": 0,
    "curPrice": 0.018,
    "title": "Will Elon Musk post 90-99 tweets from January 5 to January 7, 2026?"
}
```
