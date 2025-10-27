# Issue #26: Minimal Alpaca Entity Reference Data (MVP)

**Status**: Ready for Implementation
**Priority**: High - Foundational for NER Entity Linking
**Scope**: MVP only - no enrichment, no multi-source, no aliases
**Phase**: Market Data Foundation

---

## Philosophy

**"Test the API first. Store the basics. Expand later."**

This is a MINIMAL implementation to get Alpaca entity data into the database. We're deliberately avoiding:
- ❌ Yahoo Finance enrichment
- ❌ Entity aliases table
- ❌ Index memberships
- ❌ Sector/industry classification
- ❌ Market cap or financial metrics
- ❌ Multi-source data merging

We can add ALL of those later. For MVP, focus on: **Get Alpaca data → Store it → Look it up**

---

## Phase 0: Reconnaissance (REQUIRED FIRST)

**Before writing any code**, you need real data from Alpaca API.

### Step 0.1: Set Up Alpaca Account
1. Create Alpaca paper trading account at https://alpaca.markets
2. Generate API credentials (Key ID + Secret Key)
3. Store in `.env` (never commit):
   ```bash
   ALPACA_API_KEY=your_key_here
   ALPACA_SECRET_KEY=your_secret_here
   ALPACA_BASE_URL=https://paper-api.alpaca.markets
   ```

### Step 0.2: Test the API Manually
Test the `/v2/assets` endpoint to see what Alpaca actually returns:

```bash
# Test request
curl -X GET "https://paper-api.alpaca.markets/v2/assets?status=active&asset_class=us_equity" \
  -H "APCA-API-KEY-ID: your_key" \
  -H "APCA-API-SECRET-KEY: your_secret"
```

### Step 0.3: Document Real Response
Create a file documenting what Alpaca actually returns:

```
.github/ALPACA_API_RESPONSE.md
---
Sample response from /v2/assets endpoint:
- What fields are included?
- What do they look like?
- Any unexpected data?
- Any missing fields we expected?
```

**ONLY proceed to Phase 1 after completing reconnaissance.**

---

## Phase 1: Minimal Schema

### Migration: `create_market_entities.exs`

Create ONE table with ONLY essential Alpaca fields:

```elixir
defmodule VolfefeMachine.Repo.Migrations.CreateMarketEntities do
  use Ecto.Migration

  def change do
    create table(:market_entities, primary_key: false) do
      add :id, :uuid, primary_key: true           # Alpaca's UUID
      add :symbol, :string, null: false            # "TSLA", "AAPL"
      add :name, :string, null: false              # "Tesla Inc"
      add :exchange, :string, null: false          # "NASDAQ", "NYSE"
      add :asset_class, :string, null: false       # "us_equity", "crypto"
      add :status, :string, null: false            # "active", "inactive"
      add :tradable, :boolean, null: false         # true/false

      # Source tracking (for future multi-source expansion)
      add :data_source, :string, default: "alpaca" # Always "alpaca" for MVP
      add :last_updated, :utc_datetime             # When we fetched this

      timestamps(type: :utc_datetime)
    end

    # Essential indexes only
    create unique_index(:market_entities, [:symbol])
    create index(:market_entities, [:asset_class])
    create index(:market_entities, [:status])
    create index(:market_entities, [:exchange])
  end
end
```

**That's it.** No sector, no industry, no market cap. Add those LATER.

### Schema: `lib/volfefe_machine/market_entity.ex`

```elixir
defmodule VolfefeMachine.MarketEntity do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  schema "market_entities" do
    field :symbol, :string
    field :name, :string
    field :exchange, :string
    field :asset_class, :string
    field :status, :string
    field :tradable, :boolean
    field :data_source, :string
    field :last_updated, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def changeset(entity, attrs) do
    entity
    |> cast(attrs, [:id, :symbol, :name, :exchange, :asset_class,
                    :status, :tradable, :data_source, :last_updated])
    |> validate_required([:id, :symbol, :name, :exchange, :asset_class,
                          :status, :tradable])
    |> unique_constraint(:symbol)
  end
end
```

---

## Phase 2: Alpaca API Client

### Client: `lib/volfefe_machine/alpaca/client.ex`

Simple HTTP client using `req` (add to mix.exs):

```elixir
defmodule VolfefeMachine.Alpaca.Client do
  @moduledoc """
  Minimal Alpaca API client for fetching asset data.
  """

  @base_url "https://paper-api.alpaca.markets"

  def fetch_assets(opts \\ []) do
    status = Keyword.get(opts, :status, "active")
    asset_class = Keyword.get(opts, :asset_class, "us_equity")

    url = "#{base_url()}/v2/assets"

    Req.get(url,
      params: %{status: status, asset_class: asset_class},
      headers: auth_headers()
    )
    |> handle_response()
  end

  defp base_url do
    System.get_env("ALPACA_BASE_URL", @base_url)
  end

  defp auth_headers do
    %{
      "APCA-API-KEY-ID" => System.fetch_env!("ALPACA_API_KEY"),
      "APCA-API-SECRET-KEY" => System.fetch_env!("ALPACA_SECRET_KEY")
    }
  end

  defp handle_response({:ok, %{status: 200, body: body}}) do
    {:ok, body}
  end
  defp handle_response({:ok, %{status: status, body: body}}) do
    {:error, {:api_error, status, body}}
  end
  defp handle_response({:error, reason}) do
    {:error, {:http_error, reason}}
  end
end
```

**Add to mix.exs**:
```elixir
{:req, "~> 0.5.0"}
```

---

## Phase 3: Data Loader

### Loader: `lib/volfefe_machine/alpaca/entity_loader.ex`

Simple module to fetch and store:

```elixir
defmodule VolfefeMachine.Alpaca.EntityLoader do
  @moduledoc """
  Loads market entity data from Alpaca API into database.
  MVP: Simple upsert, no complex logic.
  """

  alias VolfefeMachine.{Repo, MarketEntity}
  alias VolfefeMachine.Alpaca.Client

  require Logger

  def load_all_entities do
    Logger.info("Loading market entities from Alpaca API...")

    with {:ok, assets} <- Client.fetch_assets() do
      results =
        assets
        |> Enum.map(&upsert_entity/1)
        |> Enum.group_by(fn {status, _} -> status end)

      success_count = length(results[:ok] || [])
      error_count = length(results[:error] || [])

      Logger.info("Loaded #{success_count} entities, #{error_count} errors")

      {:ok, %{success: success_count, errors: error_count}}
    end
  end

  defp upsert_entity(asset_data) do
    attrs = %{
      id: asset_data["id"],
      symbol: asset_data["symbol"],
      name: asset_data["name"],
      exchange: asset_data["exchange"],
      asset_class: asset_data["class"],
      status: asset_data["status"],
      tradable: asset_data["tradable"],
      data_source: "alpaca",
      last_updated: DateTime.utc_now()
    }

    %MarketEntity{}
    |> MarketEntity.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace_all_except, [:id, :inserted_at]},
      conflict_target: :symbol
    )
  end
end
```

---

## Phase 4: Basic Lookup Functions

### Query: Add to `MarketEntity` module

```elixir
defmodule VolfefeMachine.MarketEntity do
  # ... existing schema code ...

  alias VolfefeMachine.Repo
  import Ecto.Query

  def get_by_symbol(symbol) when is_binary(symbol) do
    symbol
    |> String.upcase()
    |> then(&Repo.get_by(__MODULE__, symbol: &1))
  end

  def list_active_equities do
    __MODULE__
    |> where([e], e.status == "active" and e.asset_class == "us_equity")
    |> order_by([e], asc: e.symbol)
    |> Repo.all()
  end

  def search_by_name(search_term) do
    pattern = "%#{search_term}%"

    __MODULE__
    |> where([e], ilike(e.name, ^pattern) or ilike(e.symbol, ^pattern))
    |> where([e], e.status == "active")
    |> limit(20)
    |> Repo.all()
  end
end
```

---

## Phase 5: Manual Testing

Test in IEx:

```elixir
# Load entities
{:ok, stats} = VolfefeMachine.Alpaca.EntityLoader.load_all_entities()

# Lookup by symbol
VolfefeMachine.MarketEntity.get_by_symbol("TSLA")

# Search
VolfefeMachine.MarketEntity.search_by_name("tesla")

# List all
VolfefeMachine.MarketEntity.list_active_equities() |> length()
```

---

## Future Enhancements (NOT for MVP)

Once MVP is working, consider adding:

### Phase 6 (Later): Yahoo Finance Enrichment
- Add fields: sector, industry, market_cap, country
- Create separate enrichment worker
- Handle rate limits and failures gracefully

### Phase 7 (Later): Entity Aliases
- Create `entity_aliases` table
- Map "Tesla" → "TSLA", "Tesla Inc" → "TSLA"
- Handle common variations

### Phase 8 (Later): Index Memberships
- Track which entities are in S&P 500, Dow Jones, etc.
- Useful for sector-wide impact analysis

### Phase 9 (Later): Automated Updates
- Schedule daily/weekly Alpaca data refresh
- Detect new IPOs and delistings
- Handle symbol changes

---

## Implementation Checklist

### Phase 0: Reconnaissance
- [ ] Create Alpaca paper trading account
- [ ] Get API credentials
- [ ] Test `/v2/assets` endpoint manually
- [ ] Document actual API response
- [ ] Confirm field names and structure

### Phase 1: Schema
- [ ] Create migration for `market_entities` table
- [ ] Create `MarketEntity` schema
- [ ] Run migration
- [ ] Verify table structure in database

### Phase 2: API Client
- [ ] Add `req` dependency to mix.exs
- [ ] Create `Alpaca.Client` module
- [ ] Add environment variables to config
- [ ] Test API connection manually

### Phase 3: Data Loader
- [ ] Create `Alpaca.EntityLoader` module
- [ ] Implement `load_all_entities/0`
- [ ] Test upsert logic
- [ ] Verify data in database

### Phase 4: Lookups
- [ ] Add `get_by_symbol/1` function
- [ ] Add `list_active_equities/0` function
- [ ] Add `search_by_name/1` function
- [ ] Test all lookup functions

### Phase 5: Testing
- [ ] Load ~100 entities successfully
- [ ] Verify symbol lookup works
- [ ] Verify search works
- [ ] Document any issues

---

## Success Criteria

**MVP is complete when:**
1. ✅ Alpaca API connection works
2. ✅ Can load active US equities into database
3. ✅ Can look up entity by symbol (e.g., "TSLA")
4. ✅ Database has ~9,000+ active US equity symbols
5. ✅ Data updates successfully (upsert works)

**NOT required for MVP:**
- ❌ Scheduled updates
- ❌ Yahoo Finance enrichment
- ❌ Aliases or variations
- ❌ Index memberships
- ❌ Advanced search features

---

## Estimated Time

- **Phase 0 (Reconnaissance)**: 30-60 minutes
- **Phase 1 (Schema)**: 30 minutes
- **Phase 2 (API Client)**: 45 minutes
- **Phase 3 (Data Loader)**: 1 hour
- **Phase 4 (Lookups)**: 30 minutes
- **Phase 5 (Testing)**: 30 minutes

**Total MVP**: ~4-5 hours

Future enhancements can be added incrementally as separate issues.

---

## Dependencies

**Required:**
- PostgreSQL with UUID support
- Alpaca paper trading account (free)
- `req` HTTP client library

**Not Required:**
- Oban (can add scheduled updates later)
- Yahoo Finance API
- External enrichment services

---

## Notes

- Keep it simple - this is foundational data
- Focus on reliability over features
- Add complexity incrementally based on real needs
- Document what Alpaca actually returns, not what we assume
