# Seed file for insider reference cases
# Run with: mix run priv/repo/seeds/insider_reference_cases.exs

import Ecto.Query
alias VolfefeMachine.Repo
alias VolfefeMachine.Polymarket.InsiderReferenceCase

# Upsert helper - insert or update by case_name
defmodule Seeds.ReferenceCases do
  def upsert(attrs) do
    case Repo.get_by(InsiderReferenceCase, case_name: attrs.case_name) do
      nil ->
        %InsiderReferenceCase{}
        |> InsiderReferenceCase.changeset(attrs)
        |> Repo.insert!()

      existing ->
        existing
        |> InsiderReferenceCase.changeset(attrs)
        |> Repo.update!()
    end
  end
end

IO.puts("\n🔍 Seeding Insider Reference Cases...\n")

# =============================================================================
# POLYMARKET CASES
# =============================================================================

Seeds.ReferenceCases.upsert(%{
  case_name: "Venezuela/Maduro Raid",
  event_date: ~D[2026-01-07],
  platform: "polymarket",
  category: "politics",
  reported_profit: Decimal.new("400000"),
  reported_bet_size: Decimal.new("30000"),
  pattern_type: "new_account_large_bet",
  status: "suspected",
  description: """
  Just hours before a U.S.-led raid to capture Venezuelan President Nicolás Maduro,
  a newly created Polymarket account wagered over $30,000 that Maduro would be removed
  by end of January 2026. When the secret raid occurred, the bet paid out around $400,000.
  The timing and size of the bet strongly suggest the trader had advance, non-public
  knowledge of the government operation. This sparked widespread outcry and calls for
  regulation. U.S. Rep. Ritchie Torres cited this case while introducing legislation
  to ban officials from such trades.
  """,
  source_urls: [
    "https://www.theatlantic.com/technology/2026/01/venezuela-maduro-polymarket-prediction-markets/685526/",
    "https://ritchietorres.house.gov/posts/in-response-to-suspicious-polymarket-trade-preceding-maduro-operation-rep-ritchie-torres-introduces-legislation-to-crack-down-on-insider-trading-on-prediction-markets"
  ]
})
IO.puts("  ✅ Venezuela/Maduro Raid")

Seeds.ReferenceCases.upsert(%{
  case_name: "Nobel Peace Prize 2025",
  event_date: ~D[2025-10-10],
  platform: "polymarket",
  category: "awards",
  reported_profit: Decimal.new("10000"),
  reported_bet_size: nil,
  pattern_type: "surge_before_secret",
  status: "investigated",
  description: """
  Hours before the 2025 Nobel Peace Prize announcement, heavy betting surged on
  María Corina Machado (Venezuelan opposition leader) as the winner. This was
  highly suspicious since an entirely secret committee selects the laureate.
  Machado indeed won, and Nobel officials suspect a leak of the decision.
  The Nobel Institute director stated: "we have been prey to a criminal actor
  who wants to earn money on our information." The incident is under investigation
  for possible insider trading on leaked prize information.
  """,
  source_urls: [
    "https://www.theguardian.com/world/2025/oct/10/nobel-peace-prize-bets-polymarket"
  ]
})
IO.puts("  ✅ Nobel Peace Prize 2025")

Seeds.ReferenceCases.upsert(%{
  case_name: "Google Year in Search 2025",
  event_date: ~D[2025-12-10],
  platform: "polymarket",
  category: "tech",
  reported_profit: Decimal.new("1000000"),
  reported_bet_size: nil,
  pattern_type: "embargo_breach",
  status: "suspected",
  description: """
  Google's Year-in-Search 2025 (annual top search trends) was supposed to be secret
  until official release, but Google accidentally indexed the data early. A trader
  spotted this and placed near-perfect bets on which terms would top the list.
  Within ~24 hours, the account netted over $1 million in profit. This prompted
  debate over leaks and insider info on crypto-based prediction markets, since
  the odds swung dramatically just before Google's announcement.
  """,
  source_urls: [
    "https://www.reddit.com/r/CryptoCurrency/comments/1penpfg/alleged_insider_nets_over_1m_on_polymarket_using/",
    "https://gizmodo.com/tracking-insider-trading-on-polymarket-is-turning-into-a-business-of-its-own-2000709286"
  ]
})
IO.puts("  ✅ Google Year in Search 2025")

Seeds.ReferenceCases.upsert(%{
  case_name: "OpenAI Browser Launch",
  event_date: ~D[2025-10-28],
  platform: "polymarket",
  category: "tech",
  reported_profit: Decimal.new("7000"),
  reported_bet_size: Decimal.new("40000"),
  pattern_type: "new_account_large_bet",
  status: "suspected",
  description: """
  A brand-new account wagered ~$40,000 that OpenAI would launch a web browser
  by end of October 2025. Shortly after, OpenAI did launch a browser feature,
  and the trader made about $7,000 profit in days. The unusually large, well-timed
  bet was flagged as likely based on insider knowledge of OpenAI's product plans.
  """,
  source_urls: [
    "https://gizmodo.com/tracking-insider-trading-on-polymarket-is-turning-into-a-business-of-its-own-2000709286"
  ]
})
IO.puts("  ✅ OpenAI Browser Launch")

# =============================================================================
# EXTERNAL CASES (Pattern Reference)
# =============================================================================

Seeds.ReferenceCases.upsert(%{
  case_name: "Coinbase Listing Scheme",
  event_date: ~D[2022-04-01],
  platform: "coinbase",
  category: "crypto",
  reported_profit: Decimal.new("1100000"),
  reported_bet_size: nil,
  pattern_type: "serial_front_running",
  status: "confirmed",
  description: """
  A Coinbase product manager, Ishan Wahi, engaged in a year-long insider scheme
  involving upcoming token listings on the exchange. From June 2021 to April 2022,
  Wahi had confidential knowledge of which crypto assets Coinbase planned to list.
  He tipped off his brother and a friend about at least 25 different tokens before
  they were listed. Over multiple trades they netted illicit profits totaling ~$1.1M.
  This was the first-ever crypto insider trading case prosecuted in the U.S.
  Wahi later pled guilty and was sentenced to 2 years in prison.
  """,
  source_urls: [
    "https://www.sec.gov/newsroom/press-releases/2022-127"
  ]
})
IO.puts("  ✅ Coinbase Listing Scheme (confirmed)")

Seeds.ReferenceCases.upsert(%{
  case_name: "Kodak CEO Trading",
  event_date: ~D[2020-06-23],
  platform: "nyse",
  category: "corporate",
  reported_profit: nil,
  reported_bet_size: Decimal.new("103000"),
  pattern_type: "executive_insider",
  status: "confirmed",
  description: """
  In summer 2020, Kodak's CEO (James Continenza) secretly purchased ~46,700 Kodak
  shares at ~$2.22 on June 23, while negotiating a confidential $655M federal loan
  for Kodak to pivot into pharma. A month later the U.S. announced the loan and
  Kodak's stock soared to $60+ per share - a 27x increase. The New York Attorney
  General called it "illegal insider trading," noting Kodak's CEO "used insider
  information to illegally trade company stock" during the pandemic.
  """,
  source_urls: [
    "https://ag.ny.gov/press-release/2021/attorney-general-james-secures-court-order-forcing-kodak-ceo-publicly-testify"
  ]
})
IO.puts("  ✅ Kodak CEO Trading (confirmed)")

Seeds.ReferenceCases.upsert(%{
  case_name: "Activision/MSFT Options",
  event_date: ~D[2022-01-14],
  platform: "nasdaq",
  category: "corporate",
  reported_profit: Decimal.new("60000000"),
  reported_bet_size: nil,
  pattern_type: "pre_merger_options",
  status: "investigated",
  description: """
  Just days before Microsoft announced its $68.7B acquisition of Activision Blizzard,
  a group of well-connected investors - media mogul David Geffen, IAC chairman
  Barry Diller, and Alexander von Furstenberg - made huge bets on Activision.
  In early January 2022 they bought a large batch of Activision call options
  while the stock was around $63. After the takeover news, Activision stock
  jumped to ~$80+, yielding an unrealized profit of ~$60 million. The Wall Street
  Journal reported U.S. Federal prosecutors and the SEC opened an insider trading
  probe. All three denied having any non-public info.
  """,
  source_urls: [
    "https://www.reuters.com/technology/us-probes-options-trade-gained-microsoft-activision-deal-wsj-2022-03-09/",
    "https://finance.yahoo.com/news/microsofts-75b-acquisition-activision-cleared-204303332.html"
  ]
})
IO.puts("  ✅ Activision/MSFT Options (investigated)")

Seeds.ReferenceCases.upsert(%{
  case_name: "Twitter/Musk Options",
  event_date: ~D[2022-03-31],
  platform: "nyse",
  category: "tech",
  reported_profit: nil,
  reported_bet_size: Decimal.new("530000"),
  pattern_type: "pre_disclosure_options",
  status: "suspected",
  description: """
  In the days leading up to April 4, 2022 (when Elon Musk disclosed his 9.2% stake
  in Twitter), options analysts observed a flurry of bullish trades in Twitter's
  options market. On March 31, a trader bought 3,900 TWTR call contracts for about
  $530,000 just minutes before market close. When Musk's stake was revealed
  (stock spiked ~26%), those calls' value soared ~400%. Market experts said
  "it certainly seems someone was aware of Musk building a stake."
  """,
  source_urls: [
    "https://www.reuters.com/technology/twitter-options-trades-ahead-musk-disclosure-raise-analysts-eyebrows-2022-04-04/"
  ]
})
IO.puts("  ✅ Twitter/Musk Options (suspected)")

Seeds.ReferenceCases.upsert(%{
  case_name: "NCAA Baseball Betting",
  event_date: ~D[2023-04-28],
  platform: "sportsbook",
  category: "sports",
  reported_profit: Decimal.new("15000"),
  reported_bet_size: Decimal.new("100000"),
  pattern_type: "injury_info_leak",
  status: "confirmed",
  description: """
  In a college baseball game (University of Alabama vs. LSU), Alabama's head coach
  Brad Bohannon had inside knowledge that his starting pitcher was a late scratch
  due to injury. Shortly before the game, Bohannon texted a gambler friend this info.
  Armed with this tip, the bettor rushed to a sportsbook and attempted to wager
  $100,000 against Alabama. The sportsbook flagged the bet and only accepted $15,000,
  but LSU did win. Within days, Bohannon was fired. The gambler (Bert Neff) pleaded
  guilty to federal charges including wire fraud. This led to NCAA penalties and
  a 15-year ban for the coach.
  """,
  source_urls: [
    "https://www.espn.com/espn/betting/story/_/id/39436918/brad-bohannon-ex-alabama-baseball-coach-sanctioned-betting-scandal",
    "https://www.thezone1059.com/5-of-the-biggest-sports-betting-scandals-in-us-history/"
  ]
})
IO.puts("  ✅ NCAA Baseball Betting (confirmed)")

# Summary
count = Repo.aggregate(InsiderReferenceCase, :count)
confirmed = Repo.aggregate(
  from(r in InsiderReferenceCase, where: r.status == "confirmed"),
  :count
)
polymarket = Repo.aggregate(
  from(r in InsiderReferenceCase, where: r.platform == "polymarket"),
  :count
)

IO.puts("""

📊 Insider Reference Cases Summary:
   Total cases: #{count}
   Confirmed: #{confirmed}
   Polymarket: #{polymarket}
   External: #{count - polymarket}
""")
