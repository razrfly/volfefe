defmodule Mix.Tasks.Polymarket.SeedInsiders do
  @moduledoc """
  Import documented insider trading cases as seed data for validation.

  Seeds confirmed insider cases from external research into the database
  for training and validation of the detection system.

  ## Commands

      # List available seed cases
      mix polymarket.seed_insiders --list

      # Import all seed cases
      mix polymarket.seed_insiders --import

      # Import specific case by number
      mix polymarket.seed_insiders --import --case 1

      # Dry run (show what would be imported)
      mix polymarket.seed_insiders --import --dry-run

      # Look up condition_ids for markets (requires API)
      mix polymarket.seed_insiders --lookup-markets

  ## Seed Data Sources

  Cases are compiled from:
  - NPR, Bloomberg, Forbes investigations
  - Lookonchain on-chain analysis
  - Congressional records
  - CFTC investigations

  ## Data Structure

  Each case includes:
  - wallet_address: Ethereum address (required for TIER 1)
  - market_question: Market description
  - condition_id: Polymarket condition ID (may need lookup)
  - category: politics, corporate, crypto, etc.
  - trade_info: Date, side, size, price, outcome
  - evidence: Source links and summaries
  - confidence: suspected, likely, confirmed
  """

  use Mix.Task
  alias VolfefeMachine.Polymarket
  alias VolfefeMachine.Polymarket.ConfirmedInsider
  alias VolfefeMachine.Repo

  @shortdoc "Import documented insider trading cases as seed data"

  # TIER 1: Cases with complete wallet addresses
  @seed_cases [
    %{
      case_number: 1,
      wallet_address: "0x31a56e9E690c621eD21De08Cb559e9524Cdb8eD9",
      market_question: "Will Nicolás Maduro be out of office by January 31, 2026?",
      condition_id: nil, # Needs lookup
      category: "politics",
      trade_date: ~D[2026-01-02],
      side: "buy",
      outcome: "Yes",
      trade_size: Decimal.new("34000"),
      price_at_trade: 0.06,
      confidence_level: "likely",
      confirmation_source: "news_report",
      estimated_profit: Decimal.new("409900"),
      evidence_summary: """
      Account 'Burdensome-Mix' created December 27, 2025 (1 week before capture).
      Bet placed hours before US military operation. Trump confirmed 'leaker' was jailed.
      CFTC opened formal investigation January 2026.
      """,
      evidence_links: %{
        npr: "https://www.npr.org/2026/01/05/nx-s1-5667232/polymarket-maduro-bet-insider-trading",
        lookonchain: "https://x.com/lookonchain/status/2007639475497881625",
        congress: "https://ritchietorres.house.gov/posts/in-response-to-suspicious-polymarket-trade-preceding-maduro-operation"
      }
    },
    %{
      case_number: 2,
      wallet_address: "0xa72DB1749e9AC2379D49A3c12708325ED17FeBd4",
      market_question: "Will US forces enter Venezuela by February 2026?",
      condition_id: nil, # Needs lookup
      category: "politics",
      trade_date: ~D[2026-01-02],
      side: "buy",
      outcome: "Yes",
      trade_size: Decimal.new("5800"),
      price_at_trade: 0.07,
      confidence_level: "likely",
      confirmation_source: "blockchain_analysis",
      estimated_profit: Decimal.new("75000"),
      evidence_summary: """
      Second wallet identified betting on Venezuela outcomes. Part of coordinated 3-wallet pattern.
      All wallets only bet on Venezuela-related markets. Created days before event.
      """,
      evidence_links: %{
        lookonchain: "https://x.com/lookonchain/status/2007639475497881625"
      }
    },
    # Note: Cases 11-13 have partial wallet "0xafEe" - need full address lookup
    # Google Year in Search insider with $1.3M profit
    %{
      case_number: 11,
      wallet_address: nil, # Partial: "0xafEe" - needs full lookup
      wallet_partial: "0xafEe",
      market_question: "Google Year in Search 2025 - Most Searched Person",
      condition_id: nil,
      category: "corporate",
      trade_date: ~D[2025-12-04],
      side: "buy",
      outcome: "d4vd",
      trade_size: Decimal.new("10647"),
      price_at_trade: 0.06,
      confidence_level: "likely",
      confirmation_source: "blockchain_analysis",
      estimated_profit: Decimal.new("1300000"), # Combined across all Google markets
      evidence_summary: """
      Trader 'AlphaRaccoon' achieved 22/23 correct predictions across Google markets.
      Account deposited $3M Friday before betting. Predicted obscure winner d4vd (20-year-old singer at 0.2% odds).
      Google accidentally pushed results early confirming accuracy.
      Meta engineer accused trader of being Google insider.
      """,
      evidence_links: %{
        gizmodo: "https://gizmodo.com/polymarket-user-accused-of-1-million-insider-trade-on-google-search-markets-2000696258",
        yahoo: "https://finance.yahoo.com/news/polymarket-trader-makes-1-million-090001027.html",
        beincrypto: "https://beincrypto.com/alleged-google-insider-trade-polymarket/"
      }
    },

    # ============================================================================
    # TIER 2 Cases from Second Research (ChatGPT analysis) - Need wallet lookup
    # Source: Summary of Cases by Category and Confidence.pdf
    # ============================================================================

    # Case 12: CZ Pardon (Crypto category - UPGRADED with wallet research)
    %{
      case_number: 12,
      wallet_address: nil,  # Associated with ereignis.eth - needs ENS resolution
      wallet_partial: "ereignis.eth",  # ENS name linked to bigwinner01 account
      market_question: "Will Trump pardon CZ in 2025?",
      condition_id: nil,
      category: "crypto",
      trade_date: ~D[2025-10-23],
      side: "buy",
      outcome: "Yes",
      trade_size: Decimal.new("28677"),
      price_at_trade: 0.33,
      confidence_level: "likely",
      confirmation_source: "blockchain_analysis",
      estimated_profit: Decimal.new("56824"),
      evidence_summary: """
      Polymarket account 'bigwinner01' placed $28k bet on CZ pardon hours before announcement.
      Linked to ereignis.eth wallet and Hyperliquid whale who made $190M shorting before Trump tweets.
      Coffeezilla investigation exposed connection. 199% profit in single trade.
      Price jumped from $0.33 to $0.999 within an hour before White House announcement.
      """,
      evidence_links: %{
        coffeezilla: "https://x.com/coffeebreak_YT/status/1981410072975856019",
        yahoo_finance: "https://finance.yahoo.com/news/coffeezilla-alleges-insider-trading-polymarket-081715252.html",
        ccn: "https://www.ccn.com/news/crypto/coffeezilla-trump-cz-pardon-insider-trading-trader/"
      }
    },

    # Case 13: Monad Airdrop (Crypto category - NEW from second research)
    %{
      case_number: 13,
      wallet_address: nil,
      wallet_partial: nil,
      market_question: "Monad Airdrop timing/eligibility market",
      condition_id: nil,
      category: "crypto",
      trade_date: nil,
      side: "buy",
      outcome: nil,
      trade_size: nil,
      price_at_trade: nil,
      confidence_level: "suspected",
      confirmation_source: "pattern_match",
      estimated_profit: nil,
      evidence_summary: """
      Suspicious trading activity on Monad airdrop-related markets.
      Wallet addresses and specific trade details not publicly documented.
      Potential insider knowledge of airdrop eligibility criteria or timing.
      """,
      evidence_links: %{
        source: "ChatGPT research compilation - January 2026"
      }
    },

    # Case 14: Infinex ICO (Crypto category - NEW from second research)
    %{
      case_number: 14,
      wallet_address: nil,
      wallet_partial: nil,
      market_question: "Infinex ICO outcome market",
      condition_id: nil,
      category: "crypto",
      trade_date: nil,
      side: "buy",
      outcome: nil,
      trade_size: nil,
      price_at_trade: nil,
      confidence_level: "suspected",
      confirmation_source: "pattern_match",
      estimated_profit: nil,
      evidence_summary: """
      Suspected insider activity on Infinex ICO-related prediction markets.
      May involve knowledge of token sale outcomes or regulatory decisions.
      No wallet addresses publicly documented.
      """,
      evidence_links: %{
        source: "ChatGPT research compilation - January 2026"
      }
    },

    # Case 15: Netflix Show Cancellation (Entertainment category - NEW from second research)
    %{
      case_number: 15,
      wallet_address: nil,
      wallet_partial: nil,
      market_question: "Netflix show cancellation/renewal market",
      condition_id: nil,
      category: "entertainment",
      trade_date: nil,
      side: nil,
      outcome: nil,
      trade_size: nil,
      price_at_trade: nil,
      confidence_level: "suspected",
      confirmation_source: "pattern_match",
      estimated_profit: nil,
      evidence_summary: """
      Suspected insider trading on Netflix content decisions.
      Could involve Netflix employees or production company staff with
      advance knowledge of renewal/cancellation decisions.
      No wallet addresses or specific trades publicly documented.
      """,
      evidence_links: %{
        source: "ChatGPT research compilation - January 2026"
      }
    },

    # Case 16: NBA Betting Anomalies (Sports category - NEW from second research)
    %{
      case_number: 16,
      wallet_address: nil,
      wallet_partial: nil,
      market_question: "NBA game outcome markets",
      condition_id: nil,
      category: "sports",
      trade_date: nil,
      side: nil,
      outcome: nil,
      trade_size: nil,
      price_at_trade: nil,
      confidence_level: "suspected",
      confirmation_source: "pattern_match",
      estimated_profit: nil,
      evidence_summary: """
      Suspicious betting patterns on NBA game markets.
      Could involve player injury knowledge, lineup decisions, or game-fixing.
      Sports betting anomalies are historically common but hard to prove.
      No specific wallet addresses documented.
      """,
      evidence_links: %{
        source: "ChatGPT research compilation - January 2026"
      }
    },

    # Case 17: Israel Strike (Politics/Military category - UPGRADED with wallet research)
    %{
      case_number: 17,
      wallet_address: "0x0afc7ce56285bde1fbe3a75efaffdfc86d6530b2",
      wallet_partial: nil,
      market_question: "Israel strikes Iran/Yemen military action markets",
      condition_id: nil,
      category: "politics",
      trade_date: ~D[2026-01-07],
      side: "buy",
      outcome: "Yes",
      trade_size: Decimal.new("8198"),
      price_at_trade: 0.21,
      confidence_level: "likely",
      confirmation_source: "blockchain_analysis",
      estimated_profit: Decimal.new("155699"),
      evidence_summary: """
      Polymarket account 'ricosuave666' with 100% win rate on Israel-related bets.
      $155k+ total profits from Israel strike markets. Dormant 7 months, returned Jan 2026.
      Every single Israel-related bet was profitable. Lookonchain flagged as potential insider.
      Now betting on strikes by Jan 31 and Mar 31, 2026 - odds jumped from 21% to 38%.
      Pattern mirrors Venezuela insider trading structure.
      """,
      evidence_links: %{
        lookonchain: "https://x.com/lookonchain/status/2008723345844662575",
        beincrypto: "https://beincrypto.com/polymarket-trader-israel-iran-bet-returns/",
        dyutam: "https://dyutam.com/news/polymarket-israel-iran-conflict-insider-trading/"
      }
    }
  ]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} = OptionParser.parse(args,
      switches: [
        list: :boolean,
        import: :boolean,
        case: :integer,
        dry_run: :boolean,
        lookup_markets: :boolean,
        force: :boolean
      ],
      aliases: [
        l: :list,
        i: :import,
        c: :case,
        d: :dry_run,
        f: :force
      ]
    )

    cond do
      opts[:list] ->
        list_cases()

      opts[:lookup_markets] ->
        lookup_markets()

      opts[:import] ->
        import_cases(opts)

      true ->
        print_help()
    end
  end

  # ============================================================================
  # Commands
  # ============================================================================

  defp list_cases do
    print_header("SEED INSIDER CASES")

    importable = Enum.filter(@seed_cases, & &1.wallet_address)
    needs_wallet_lookup = Enum.filter(@seed_cases, &(&1[:wallet_partial] && !&1.wallet_address))
    needs_research = Enum.filter(@seed_cases, &(is_nil(&1.wallet_address) && is_nil(&1[:wallet_partial])))

    Mix.shell().info("TIER 1 - Ready to Import (#{length(importable)} cases):")
    Mix.shell().info("")

    Enum.each(importable, fn case_data ->
      icon = confidence_icon(case_data.confidence_level)
      wallet = format_wallet(case_data.wallet_address)
      profit = format_money(case_data.estimated_profit)

      Mix.shell().info("  #{icon} Case #{case_data.case_number}: #{wallet}")
      Mix.shell().info("     Market: #{truncate(case_data.market_question, 50)}")
      Mix.shell().info("     Category: #{case_data.category} | Profit: #{profit}")
      Mix.shell().info("")
    end)

    if length(needs_wallet_lookup) > 0 do
      Mix.shell().info("TIER 2 - Has Partial Wallet (#{length(needs_wallet_lookup)} cases):")
      Mix.shell().info("")

      Enum.each(needs_wallet_lookup, fn case_data ->
        Mix.shell().info("  ⏳ Case #{case_data.case_number}: #{case_data[:wallet_partial]}")
        Mix.shell().info("     Market: #{truncate(case_data.market_question, 50)}")
        Mix.shell().info("     Category: #{case_data.category}")
        Mix.shell().info("")
      end)
    end

    if length(needs_research) > 0 do
      Mix.shell().info("TIER 3 - Needs Wallet Research (#{length(needs_research)} cases):")
      Mix.shell().info("")

      Enum.each(needs_research, fn case_data ->
        icon = confidence_icon(case_data.confidence_level)
        Mix.shell().info("  #{icon} Case #{case_data.case_number}: No wallet data")
        Mix.shell().info("     Market: #{truncate(case_data.market_question, 50)}")
        Mix.shell().info("     Category: #{case_data.category}")
        Mix.shell().info("")
      end)
    end

    # Check existing in database
    existing_count = Repo.aggregate(ConfirmedInsider, :count)
    Mix.shell().info("─────────────────────────────────────────────────")
    Mix.shell().info("Current database: #{existing_count} confirmed insiders")
    Mix.shell().info("Total seed cases: #{length(@seed_cases)} (#{length(importable)} importable)")
    Mix.shell().info("")
  end

  defp import_cases(opts) do
    print_header("IMPORTING SEED CASES")

    cases_to_import =
      if opts[:case] do
        Enum.filter(@seed_cases, & &1.case_number == opts[:case])
      else
        Enum.filter(@seed_cases, & &1.wallet_address)
      end

    if length(cases_to_import) == 0 do
      Mix.shell().error("No cases found to import")
      return_error()
    end

    Mix.shell().info("Cases to import: #{length(cases_to_import)}")
    Mix.shell().info("")

    if opts[:dry_run] do
      Mix.shell().info("DRY RUN - No changes will be made")
      Mix.shell().info("")
      Enum.each(cases_to_import, &print_case_preview/1)
      {:ok, :dry_run}
    else
      results = Enum.map(cases_to_import, &import_single_case(&1, opts))

      successful = Enum.count(results, &match?({:ok, _}, &1))
      skipped = Enum.count(results, &match?({:skipped, _}, &1))
      failed = Enum.count(results, &match?({:error, _}, &1))

      Mix.shell().info("")
      Mix.shell().info("─────────────────────────────────────────────────")
      Mix.shell().info("Results: #{successful} imported, #{skipped} skipped, #{failed} failed")

      # Show new total
      new_count = Repo.aggregate(ConfirmedInsider, :count)
      Mix.shell().info("Total confirmed insiders: #{new_count}")
      Mix.shell().info("")
    end
  end

  defp import_single_case(case_data, opts) do
    wallet = case_data.wallet_address

    # Check if already exists
    existing = Repo.get_by(ConfirmedInsider, wallet_address: wallet)

    cond do
      existing && !opts[:force] ->
        Mix.shell().info("⏭️  Case #{case_data.case_number}: Already exists (use --force to reimport)")
        {:skipped, :exists}

      true ->
        # Delete existing if force
        if existing && opts[:force] do
          Repo.delete(existing)
        end

        attrs = %{
          wallet_address: wallet,
          condition_id: case_data.condition_id,
          confidence_level: case_data.confidence_level,
          confirmation_source: case_data.confirmation_source,
          evidence_summary: String.trim(case_data.evidence_summary),
          evidence_links: case_data.evidence_links,
          trade_size: case_data.trade_size,
          estimated_profit: case_data.estimated_profit,
          confirmed_at: DateTime.utc_now(),
          confirmed_by: "seed_import"
        }

        case Polymarket.add_confirmed_insider(attrs) do
          {:ok, insider} ->
            Mix.shell().info("✅ Case #{case_data.case_number}: Imported #{format_wallet(wallet)}")
            {:ok, insider}

          {:error, changeset} ->
            errors = format_errors(changeset)
            Mix.shell().error("❌ Case #{case_data.case_number}: #{errors}")
            {:error, changeset}
        end
    end
  end

  defp lookup_markets do
    print_header("MARKET CONDITION ID LOOKUP")

    Mix.shell().info("Looking up condition_ids for seed case markets...")
    Mix.shell().info("")

    cases_needing_lookup = Enum.filter(@seed_cases, &is_nil(&1.condition_id))

    Enum.each(cases_needing_lookup, fn case_data ->
      Mix.shell().info("Case #{case_data.case_number}: #{truncate(case_data.market_question, 50)}")

      # Try to find matching market in database
      case find_market_by_question(case_data.market_question) do
        {:ok, market} ->
          Mix.shell().info("  ✅ Found: #{market.condition_id}")

        :not_found ->
          Mix.shell().info("  ⏳ Not found in database - needs manual lookup")
      end

      Mix.shell().info("")
    end)
  end

  defp find_market_by_question(question) do
    # Try exact match first
    import Ecto.Query

    query = from m in VolfefeMachine.Polymarket.Market,
      where: ilike(m.question, ^"%#{question}%"),
      limit: 1

    case Repo.one(query) do
      nil -> :not_found
      market -> {:ok, market}
    end
  end

  # ============================================================================
  # Output Formatting
  # ============================================================================

  defp print_case_preview(case_data) do
    icon = confidence_icon(case_data.confidence_level)
    wallet = format_wallet(case_data.wallet_address)
    profit = format_money(case_data.estimated_profit)

    Mix.shell().info("#{icon} Case #{case_data.case_number}")
    Mix.shell().info("  Wallet: #{wallet}")
    Mix.shell().info("  Market: #{truncate(case_data.market_question, 50)}")
    Mix.shell().info("  Confidence: #{case_data.confidence_level}")
    Mix.shell().info("  Source: #{case_data.confirmation_source}")
    Mix.shell().info("  Profit: #{profit}")
    Mix.shell().info("")
  end

  defp print_header(title) do
    Mix.shell().info("")
    Mix.shell().info(String.duplicate("=", 55))
    Mix.shell().info(title)
    Mix.shell().info(String.duplicate("=", 55))
    Mix.shell().info("")
  end

  defp print_help do
    Mix.shell().info("""

    Import documented insider trading cases as seed data.

    Usage:
      mix polymarket.seed_insiders --list           # List available cases
      mix polymarket.seed_insiders --import         # Import all TIER 1 cases
      mix polymarket.seed_insiders --import --case 1  # Import specific case
      mix polymarket.seed_insiders --import --dry-run # Preview without importing
      mix polymarket.seed_insiders --lookup-markets   # Find condition_ids

    Options:
      --force      Reimport existing cases (replaces)
      --dry-run    Show what would be imported without making changes

    """)
  end

  defp confidence_icon("confirmed"), do: "🚨"
  defp confidence_icon("likely"), do: "⚠️"
  defp confidence_icon("suspected"), do: "ℹ️"
  defp confidence_icon(_), do: "❓"

  defp format_wallet(nil), do: "Unknown"
  defp format_wallet(address) when byte_size(address) > 12 do
    "#{String.slice(address, 0, 6)}...#{String.slice(address, -4, 4)}"
  end
  defp format_wallet(address), do: address

  defp format_money(nil), do: "$0"
  defp format_money(%Decimal{} = d) do
    "$#{Decimal.round(d, 0) |> Decimal.to_string(:normal)}"
  end
  defp format_money(n), do: "$#{n}"

  defp truncate(nil, _), do: "N/A"
  defp truncate(str, max) when is_binary(str) do
    if String.length(str) <= max, do: str, else: String.slice(str, 0, max - 3) <> "..."
  end

  defp format_errors(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map(fn {k, v} -> "#{k}: #{Enum.join(v, ", ")}" end)
    |> Enum.join("; ")
  end

  defp return_error, do: {:error, :no_cases}
end
