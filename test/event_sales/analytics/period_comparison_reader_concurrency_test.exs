defmodule EventSales.Analytics.PeriodComparisonReaderConcurrencyTest do
  use EventSales.DataCase, async: false

  require Ash.Query

  alias EventSales.Accounts
  alias EventSales.Accounts.Resources.{Role, User, UserRole}
  alias EventSales.Analytics.PeriodComparisonReader
  alias EventSales.Analytics.Resources.EventPeriodAggregateSnapshot
  alias EventSales.Repo
  alias EventSales.TestSupport.EventDetailCertificationHelpers
  alias EventSales.TestSupport.PeriodComparisonHelpers
  alias EventSales.TestSupport.SalesHelpers

  @now ~U[2026-05-17 10:00:00.000000Z]

  setup do
    source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{name: "Period concurrency"})
    ticket = SalesHelpers.create_ticket_type!(event, %{name: "GA"})
    admin = create_user!("period-concurrency-admin@example.com")
    create_global_role!(admin, :admin)
    EventDetailCertificationHelpers.certify_analytics_ready!(event)

    PeriodComparisonHelpers.seed_comparison_projection!(
      event,
      source,
      ticket,
      "ZAR",
      :yesterday,
      @now,
      %{
        current: %{gross_ticket_quantity: 3, gross_ticket_value: Decimal.new("30.00")},
        previous: %{gross_ticket_quantity: 1, gross_ticket_value: Decimal.new("10.00")}
      }
    )

    %{event: event, admin: admin}
  end

  test "stale required bucket returns projection_not_ready", %{event: event, admin: admin} do
    import Ecto.Query

    from(row in EventPeriodAggregateSnapshot,
      where: row.event_id == ^event.id and row.projection_state == :current
    )
    |> order_by([row], asc: row.bucket_start_utc)
    |> limit(1)
    |> Repo.one!()
    |> then(fn row ->
      Repo.update_all(
        from(b in EventPeriodAggregateSnapshot, where: b.id == ^row.id),
        set: [projection_state: :stale]
      )
    end)

    assert {:error, :projection_not_ready} =
             PeriodComparisonReader.compare_event(event.id, "ZAR", :yesterday,
               actor: admin,
               now: @now
             )
  end

  defp create_user!(email) do
    Ash.create!(
      User,
      %{
        email: email,
        name: "Period Concurrency User",
        password: "valid-pass-123",
        password_confirmation: "valid-pass-123"
      },
      action: :register_with_password,
      domain: Accounts
    )
  end

  defp create_global_role!(user, role_name) do
    role =
      Role
      |> Ash.Query.filter(name == ^role_name)
      |> Ash.read_one!(domain: Accounts)
      |> case do
        nil -> Ash.create!(Role, %{name: role_name}, action: :create, domain: Accounts)
        role -> role
      end

    Ash.create!(UserRole, %{user_id: user.id, role_id: role.id},
      action: :create,
      domain: Accounts
    )
  end
end
