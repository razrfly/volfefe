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
│  • Truth Social (via Apify)   • NewsAPI   • RSS   • More│
└─────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────┐
│  INGESTION PIPELINE                                      │
│  Fetch → Normalize → Store (Postgres) → Broadcast       │
└─────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────┐
│  MULTI-MODEL CLASSIFICATION (ML Analysis) ✅             │
│  • 3 Sentiment Models: DistilBERT, Twitter-RoBERTa,     │
│    FinBERT (weighted consensus)                          │
│  • 1 NER Model: BERT-base-NER (entity extraction)       │
│  Output: Sentiment + Confidence + Entities (ORG/LOC/PER)│
└─────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────┐
│  ASSET LINKING (Phase 2 - In Progress)                  │
│  Match entities → Assets database → ContentTargets      │
└─────────────────────────────────────────────────────────┘
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

### Running Classification with Entity Extraction

Once content is ingested (see **Content Ingestion** below), you can run multi-model classification:

```bash
# Classify first 10 unclassified items with all models (sentiment + NER)
mix classify.contents --limit 10 --multi-model

# Classify all unclassified content
mix classify.contents --all --multi-model

# Classify specific content IDs
mix classify.contents --ids 1,2,3 --multi-model

# Preview what would be classified (dry run)
mix classify.contents --limit 10 --dry-run
```

**Output includes**:
- Sentiment consensus from 3 models (positive/negative/neutral)
- Confidence scores and model agreement rates
- Extracted entities: Organizations (ORG), Locations (LOC), Persons (PER), Miscellaneous (MISC)
- Entity confidence scores and context

### Environment Variables

The project uses environment variables for sensitive configuration. Copy `.env.example` to `.env` and update with your credentials:

```bash
# PostgreSQL Database
PGHOST=localhost
PGDATABASE=volfefe_machine_dev
PGUSER=postgres
PGPASSWORD=your_postgres_password

# Apify API (for Truth Social scraping)
APIFY_USER_ID=your_user_id_here
APIFY_PERSONAL_API_TOKEN=your_api_token_here
```

**⚠️ Never commit your `.env` file to version control!** It's already in `.gitignore`.

### Content Ingestion

**Status**: ✅ Complete - Unified ingestion pipeline ready

Fetch and import content from Truth Social using a single command:

```bash
# Fetch 100 posts from a specific user
mix ingest.content --source truth_social --username realDonaldTrump --limit 100

# Include replies in results
mix ingest.content --source truth_social --username realDonaldTrump --limit 50 --include-replies

# Preview what would be fetched (dry run)
mix ingest.content --source truth_social --username realDonaldTrump --limit 10 --dry-run
```

**Available Options**:
- `--source, -s` - Content source (currently: `truth_social`)
- `--username, -u` - Username/profile to fetch (required)
- `--limit, -l` - Maximum posts to fetch (default: 100)
- `--include-replies` - Include replies in results (default: false)
- `--dry-run` - Preview configuration without fetching (default: false)

---

## 🧩 Key Components

| Component | Purpose | Status |
|-----------|---------|--------|
| **Database Schema** | Assets, Contents, Classifications, ContentTargets | ✅ Complete |
| **Multi-Model Classification** | 3 sentiment models + weighted consensus | ✅ Complete |
| **NER Entity Extraction** | Extract organizations, locations, persons | ✅ Complete |
| **Apify Integration** | Fetch Truth Social posts via API | ✅ Complete |
| **Ingestion Pipeline** | Unified fetch + import workflow | ✅ Complete |
| **Asset Linking** | Match extracted entities to assets database | 📋 Phase 2 |
| **Strategy Engine** | Rule-based trade decision logic | 📋 Phase 3 |
| **Trade Executor** | Alpaca API integration | 📋 Phase 4 |
| **Dashboard** | Real-time monitoring UI | 📋 Future |

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

**`classifications`** - ML analysis results with sentiment consensus
```elixir
%Classification{
  content_id: uuid,
  sentiment: "negative",
  confidence: 0.9556,
  meta: %{
    "agreement_rate" => 1.0,
    "model_results" => [
      %{"model_id" => "distilbert", "sentiment" => "negative", "confidence" => 0.9812},
      %{"model_id" => "twitter_roberta", "sentiment" => "negative", "confidence" => 0.9654},
      %{"model_id" => "finbert", "sentiment" => "negative", "confidence" => 0.9201}
    ],
    "entities" => [
      %{"text" => "Tesla", "type" => "ORG", "confidence" => 0.9531},
      %{"text" => "United States", "type" => "LOC", "confidence" => 0.9912}
    ]
  }
}
```

**`assets`** - Tradable securities (9,000+ loaded)
```elixir
%Asset{
  symbol: "TSLA",
  name: "Tesla Inc",
  exchange: "NASDAQ",
  asset_class: "us_equity"
}
```

**`content_targets`** - Extracted entities linked to assets (Phase 2)
```elixir
%ContentTarget{
  content_id: uuid,
  asset_id: uuid,
  extraction_method: "ner_bert",
  confidence: 0.9531,
  context: "Tesla stock tumbled 12% today..."
}
```

---

## 🛠️ Tech Stack

### Backend
- **Framework**: [Phoenix 1.7](https://www.phoenixframework.org/) + [LiveView](https://hexdocs.pm/phoenix_live_view/)
- **Language**: [Elixir](https://elixir-lang.org/)
- **Database**: [PostgreSQL](https://www.postgresql.org/) with [Ecto](https://hexdocs.pm/ecto/)
- **Job Queue**: [Oban](https://hexdocs.pm/oban/) for background processing
- **HTTP Client**: [HTTPoison](https://hexdocs.pm/httpoison/) for external APIs

### Machine Learning
- **Python**: Python 3.9+ with virtual environment
- **ML Framework**: [Transformers](https://huggingface.co/docs/transformers/) (Hugging Face)
- **Models**:
  - Sentiment: DistilBERT, Twitter-RoBERTa, FinBERT
  - NER: BERT-base-NER (dslim/bert-base-NER)
- **Elixir Integration**: Python interop via `System.cmd/3`

### External Services
- **Data Source**: [Apify](https://apify.com/) for Truth Social scraping
- **Trading**: [Alpaca Markets API](https://alpaca.markets/) (future)

---

## 📅 Roadmap

### Phase 1: Foundation & ML Pipeline ✅ _(Complete)_
- [x] Project setup and architecture
- [x] Database schemas (contents, sources, classifications, assets, content_targets)
- [x] Assets database loaded (9,000+ securities)
- [x] Multi-model sentiment classification (DistilBERT, Twitter-RoBERTa, FinBERT)
- [x] Weighted consensus algorithm
- [x] NER entity extraction (BERT-base-NER)
- [x] Classification mix task with batch processing
- [x] Content ingestion - Unified mix task ([Issue #46](https://github.com/razrfly/volfefe/issues/46))
- [ ] Content backup/seeding system ([Issue #45](https://github.com/razrfly/volfefe/issues/45)) - **Next Step**

### Phase 2: Asset Linking _(In Progress)_
- [ ] Entity → Asset matching logic ([Issue #42](https://github.com/razrfly/volfefe/issues/42))
- [ ] ContentTargets creation
- [ ] Fuzzy name matching
- [ ] Confidence scoring
- [ ] Manual validation tools

### Phase 3: Strategy Engine
- [ ] Sector-to-ticker mapping
- [ ] Rule-based trade logic
- [ ] Backtesting framework
- [ ] Signal generation

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

**See**: [Issue #43 (Phase 1 NER)](https://github.com/razrfly/volfefe/issues/43) | [Issue #42 (Phase 2 Asset Linking)](https://github.com/razrfly/volfefe/issues/42)

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

## 📊 Entity Extraction Output Example

**Input Text**:
```
"Tesla stock tumbled 12% today as Elon Musk's controversial tweet sparked
concerns about the company's future. Analysts in the United States and
Europe are worried about automotive sector stability."
```

**Multi-Model Classification Output**:
```elixir
%{
  # Sentiment Consensus (3 models)
  consensus: %{
    sentiment: "negative",
    confidence: 0.9556,
    agreement_rate: 1.0
  },

  # Individual Model Results
  model_results: [
    %{model_id: "distilbert", sentiment: "negative", confidence: 0.9812},
    %{model_id: "twitter_roberta", sentiment: "negative", confidence: 0.9654},
    %{model_id: "finbert", sentiment: "negative", confidence: 0.9201}
  ],

  # Extracted Entities (NER)
  entities: [
    %{text: "Tesla", type: "ORG", confidence: 0.9531,
      context: "Tesla stock tumbled 12% today..."},
    %{text: "Elon Musk", type: "PER", confidence: 0.9802,
      context: "...12% today as Elon Musk's controversial..."},
    %{text: "United States", type: "LOC", confidence: 0.9912,
      context: "...Analysts in the United States and Europe..."},
    %{text: "Europe", type: "LOC", confidence: 0.9845,
      context: "...United States and Europe are worried..."}
  ],

  # Entity Statistics
  entity_stats: %{
    total_entities: 4,
    by_type: %{"ORG" => 1, "LOC" => 2, "PER" => 1, "MISC" => 0}
  },

  # Performance
  total_latency_ms: 663,
  successful_models: 4
}
```

**Phase 2 Preview** (not yet implemented):
- "Tesla" → Match to Asset{symbol: "TSLA", name: "Tesla Inc"}
- Create ContentTarget{content_id: X, asset_id: Y, confidence: 0.95}

---

## 📊 Example Pipeline Flow

### Current Workflow (Manual)
1. **Fetch & Import** - `mix ingest.content --source truth_social --username USER --limit 100`
2. **Content Storage** - Posts stored in PostgreSQL `contents` table
3. **Multi-Model Classification** - Run `mix classify.contents --all --multi-model`
   - 3 sentiment models analyze text (DistilBERT, Twitter-RoBERTa, FinBERT)
   - Weighted consensus calculates final sentiment + confidence
   - NER model extracts entities (ORG, LOC, PER, MISC)
4. **Results Storage** - Classifications saved to `classifications` table
5. **Entity Analysis** - Entities stored in classification metadata

### Future Automated Workflow
1. **Scheduler** (Oban) - Poll Truth Social every 60 seconds
2. **Adapter** - Fetch and normalize new posts
3. **PubSub** - Broadcast `{:new_content, content}` events
4. **Auto-Classification** - Trigger multi-model analysis on new content
5. **Asset Linking** (Phase 2) - Match entities to assets, create ContentTargets
6. **Strategy Engine** (Phase 3) - Generate trade recommendations
7. **Executor** (Phase 4) - Place orders via Alpaca API
8. **Dashboard** - Real-time monitoring via LiveView

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

### Framework & Platform
- [Phoenix Framework Docs](https://hexdocs.pm/phoenix/)
- [Elixir Getting Started](https://elixir-lang.org/getting-started/introduction.html)
- [PostgreSQL Documentation](https://www.postgresql.org/docs/)

### Machine Learning Models
- [Hugging Face Transformers](https://huggingface.co/docs/transformers/)
- [DistilBERT (SST-2)](https://huggingface.co/distilbert-base-uncased-finetuned-sst-2-english)
- [Twitter-RoBERTa Sentiment](https://huggingface.co/cardiffnlp/twitter-roberta-base-sentiment-latest)
- [FinBERT](https://huggingface.co/yiyanghkust/finbert-tone)
- [BERT-base-NER](https://huggingface.co/dslim/bert-base-NER)

### APIs & Services
- [Apify Documentation](https://docs.apify.com/)
- [Alpaca API Documentation](https://docs.alpaca.markets/)

### GitHub Issues
- [Issue #43: Phase 1 NER Entity Extraction](https://github.com/razrfly/volfefe/issues/43)
- [Issue #42: Phase 2 Asset Linking](https://github.com/razrfly/volfefe/issues/42)
- [Issue #45: Content Data Seeding](https://github.com/razrfly/volfefe/issues/45)

---

**Built with ❤️ and Elixir**
