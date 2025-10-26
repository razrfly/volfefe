defmodule VolfefeMachine.Repo do
  use Ecto.Repo,
    otp_app: :volfefe_machine,
    adapter: Ecto.Adapters.Postgres
end
