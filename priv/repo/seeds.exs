# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Inside the script, you can read and write to any of your
# repositories directly:
#
#     VolfefeMachine.Repo.insert!(%VolfefeMachine.SomeSchema{})
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.

alias VolfefeMachine.Content

# Create Truth Social source
{:ok, _source} =
  Content.create_source(%{
    name: "truth_social",
    adapter: "TruthSocialAdapter",
    base_url: "https://scrapecreators.com/api/truth_social/trump/posts",
    enabled: true,
    meta: %{
      "description" => "Donald Trump's Truth Social posts",
      "author_filter" => "realDonaldTrump"
    }
  })

IO.puts("✅ Seeded Truth Social source")
