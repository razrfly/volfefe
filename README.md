# 🤖 Volfefe Machine

> **Automated Market Volatility Trading System** - Detecting and trading on political market signals in real-time

[![Elixir](https://img.shields.io/badge/elixir-%234B275F.svg?style=for-the-badge&logo=elixir&logoColor=white)](https://elixir-lang.org/)
[![Phoenix](https://img.shields.io/badge/phoenix-%23FD4F00.svg?style=for-the-badge&logo=phoenix-framework&logoColor=white)](https://www.phoenixframework.org/)
[![PostgreSQL](https://img.shields.io/badge/postgres-%23316192.svg?style=for-the-badge&logo=postgresql&logoColor=white)](https://www.postgresql.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg?style=for-the-badge)](https://opensource.org/licenses/MIT)

---

## 🎯 What is Volfefe Machine?

Volfefe Machine is an intelligent, event-driven trading system that monitors real-time political and economic content, analyzes market impact using ML-based sentiment analysis, and executes automated trading strategies based on detected volatility signals.

**The name?** A playful nod to Trump's infamous ["covfefe" tweet](https://en.wikipedia.org/wiki/Covfefe) + volatility (vol) = **Volfefe** ⚡

### Core Concept

```
Political/Economic Event → Sentiment Analysis → Market Impact Assessment → Automated Trade
```

Starting with Truth Social posts (particularly Trump's tariff announcements), the system will expand to monitor news APIs, social media, and financial feeds to identify market-moving events before they cause significant price action.

---

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────┐
│  SOURCES (Modular Adapters)                             │
│  • Truth Social   • NewsAPI   • Reddit   • RSS   • More │
└─────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────┐
│  INGESTION PIPELINE                                      │
│  Normalize → Store (Postgres) → Broadcast (PubSub)      │
└─────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────┐
│  CLASSIFICATION (ML Analysis)                            │
│  FinBERT: Sentiment + Confidence + Sector + Entities    │
└─────────────────────────────────────────────────────────┐
                            ↓
┌─────────────────────────────────────────────────────────┐
│  STRATEGY ENGINE (Rule-Based Decisions)                 │
│  Sector Mapping → Company Selection → Trade Type        │
└─────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────┐
│  EXECUTION (Alpaca API)                                  │
│  Paper Trading → Live Trading (Options, Stocks)         │
└─────────────────────────────────────────────────────────┘
```

---

## 🚀 Quick Start

### Prerequisites

- **Elixir** 1.15+ and **Erlang/OTP** 26+
- **PostgreSQL** 14+
- **Node.js** 18+ (for Phoenix LiveView assets)

### Installation

```bash
# Clone the repository
git clone https://github.com/razrfly/volfefe.git
cd volfefe

# Install dependencies
mix deps.get
cd assets && npm install && cd ..

# Set up environment variables
cp .env.example .env
# Edit .env with your actual credentials (database password, API tokens, etc.)

# Set up database
mix ecto.setup

# (Optional) Install Python dependencies for ML scripts
python3 -m venv venv
source venv/bin/activate  # On Windows: venv\Scripts\activate
pip install -r requirements.txt

# Start Phoenix server
mix phx.server
```

Visit [`localhost:4000`](http://localhost:4000) to see the live dashboard.

### Environment Variables

The project uses environment variables for sensitive configuration. Copy `.env.example` to `.env` and update with your credentials:

```bash
# PostgreSQL Database
PGHOST=localhost
PGDATABASE=volfefe_machine_dev
PGUSER=postgres
PGPASSWORD=your_postgres_password

# Apify API (for Truth Social scraping)
APIFY_PERSONAL_API_TOKEN=your_api_token_here
```

**⚠️ Never commit your `.env` file to version control!** It's already in `.gitignore`.

---

## 🧩 Key Components

| Component | Purpose | Status |
|-----------|---------|--------|
| **Source Adapters** | Fetch content from external APIs/feeds | 🚧 Phase 1 |
| **Ingestion Pipeline** | Normalize and store content | 🚧 Phase 1 |
| **Classifier** | ML-based sentiment + sector analysis | 📋 Phase 2 |
| **Strategy Engine** | Rule-based trade decision logic | 📋 Phase 3 |
| **Trade Executor** | Alpaca API integration | 📋 Phase 4 |
| **Dashboard** | Real-time monitoring UI | 🚧 Phase 1 |

**Legend**: ✅ Complete | 🚧 In Progress | 📋 Planned

---

## 🗄️ Data Model

### Core Tables

**`sources`** - External data sources (Truth Social, NewsAPI, etc.)
```elixir
%Source{
  name: "truth_social",
  adapter: "TruthSocialAdapter",
  base_url: "https://api.example.com",
  last_fetched_at: ~U[2025-01-26 10:00:00Z]
}
```

**`contents`** - Normalized posts/articles
```elixir
%Content{
  source_id: uuid,
  external_id: "12345",
  author: "realDonaldTrump",
  text: "Big tariffs on steel coming soon!",
  url: "https://truthsocial.com/@realDonaldTrump/12345",
  published_at: ~U[2025-01-26 09:45:00Z],
  classified: false
}
```

**`classifications`** - ML analysis results (Phase 2)
```elixir
%Classification{
  content_id: uuid,
  sentiment: "negative",
  confidence: 0.92,
  sectors: ["manufacturing", "steel"],
  entities: %{"companies" => ["X", "CLF"], "countries" => ["China"]}
}
```

---

## 🛠️ Tech Stack

- **Framework**: [Phoenix 1.7](https://www.phoenixframework.org/) + [LiveView](https://hexdocs.pm/phoenix_live_view/)
- **Language**: [Elixir](https://elixir-lang.org/)
- **Database**: [PostgreSQL](https://www.postgresql.org/) with [Ecto](https://hexdocs.pm/ecto/)
- **Job Queue**: [Oban](https://hexdocs.pm/oban/) for background processing
- **ML/NLP**: [Nx](https://hexdocs.pm/nx/) + [Bumblebee](https://hexdocs.pm/bumblebee/) (FinBERT)
- **Trading**: [Alpaca Markets API](https://alpaca.markets/)
- **HTTP Client**: [Req](https://hexdocs.pm/req/)

---

## 📅 Roadmap

### Phase 1: Content Ingestion _(Current)_
- [x] Project setup and architecture
- [ ] Truth Social adapter
- [ ] Database schemas
- [ ] Oban scheduler
- [ ] PubSub event system
- [ ] LiveView dashboard

### Phase 2: ML Classification
- [ ] FinBERT integration
- [ ] Sentiment analysis
- [ ] Sector/entity extraction
- [ ] Classification database

### Phase 3: Strategy Engine
- [ ] Sector-to-ticker mapping
- [ ] Rule-based trade logic
- [ ] Backtesting framework

### Phase 4: Trade Execution
- [ ] Alpaca API integration
- [ ] Paper trading
- [ ] Risk management
- [ ] Live trading (manual approval)

### Phase 5: Multi-Source Expansion
- [ ] NewsAPI adapter
- [ ] Reddit adapter
- [ ] RSS feeds
- [ ] Source weighting

[View full roadmap in Issue #1](https://github.com/razrfly/volfefe/issues/1)

---

## 🧪 Testing

```bash
# Run all tests
mix test

# Run with coverage
mix test --cover

# Run specific test file
mix test test/volfefe/pipeline_test.exs
```

---

## 📊 Example Pipeline Flow

1. **Scheduler** (Oban) polls Truth Social every 60 seconds
2. **Adapter** fetches new posts and normalizes them
3. **Ingestor** stores posts in PostgreSQL
4. **PubSub** broadcasts `{:new_content, content}` event
5. **Classifier** (Phase 2) subscribes and analyzes sentiment/sector
6. **Strategy Engine** (Phase 3) generates trade recommendation
7. **Executor** (Phase 4) places order via Alpaca API
8. **Dashboard** updates in real-time via LiveView

---

## 🤝 Contributing

This is currently a private project, but contributions are welcome! Please:

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

---

## ⚖️ Legal & Risk Disclaimer

**This software is for educational and research purposes only.**

- Automated trading carries significant financial risk
- Past performance does not guarantee future results
- This system is not financial advice
- Use at your own risk
- Always start with paper trading
- Understand all risks before deploying real capital

**By using this software, you acknowledge that you are solely responsible for any trading decisions and outcomes.**

---

## 📄 License

MIT License - see [LICENSE](LICENSE) for details

---

## 🔗 Resources

- [Phoenix Framework Docs](https://hexdocs.pm/phoenix/)
- [Elixir Getting Started](https://elixir-lang.org/getting-started/introduction.html)
- [Alpaca API Documentation](https://docs.alpaca.markets/)
- [FinBERT Model](https://huggingface.co/ProsusAI/finbert)

---

**Built with ❤️ and Elixir**
