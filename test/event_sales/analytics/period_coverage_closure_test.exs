defmodule EventSales.Analytics.PeriodCoverageClosureTest do
  use EventSales.DataCase, async: false

  require Ash.Query

  alias EventSales.Accounts
  alias EventSales.Accounts.Resources.{Role, User, UserRole}
  alias EventSales.Analytics.PeriodComparisonReader
  alias EventSales.Analytics.PeriodCoverage
  alias EventSales.Analytics.Resources.EventPeriodAggregateSnapshot
  alias EventSales.Analytics.SnapshotRefresh
  alias EventSales.Repo
  alias EventSales.TestSupport.EventDetailCertificationHelpers
  alias EventSales.TestSupport.PeriodCoverageHelpers
  alias EventSales.TestSupport.SalesHelpers

  @now ~U[2026-05-17 10:17:33.000000Z]

  setup do
    source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{name: "Closure"})
    admin = admin_user!()
    EventDetailCertificationHelpers.certify_analytics_ready!(event)
    PeriodCoverageHelpers.seed_v2_currency!(event, "ZAR")

    %{event: event, admin: admin}
  end

  test "rolling 30 becomes READY with explicit CURRENT zero buckets after materialize and refresh",
       %{event: event, admin: admin} do
    assert {:ok, %{bucket_intents_created: created}} =
             PeriodCoverage.ensure_event_buckets(event.id, @now, enqueue_refresh?: false)

    assert created > 0

    assert {:ok, _} = SnapshotRefresh.refresh_event(event.id, now: @now)

    assert {:ok, result} =
             PeriodComparisonReader.compare_event(event.id, "ZAR", {:rolling_days, 30},
               actor: admin,
               now: @now
             )

    assert result.current.readiness == :ready
    assert result.comparison.readiness == :ready
    assert Decimal.equal?(result.current.metrics.net_ticket_quantity, Decimal.new("0"))

    zero_hour =
      EventPeriodAggregateSnapshot
      |> Ash.Query.filter(
        event_id == ^event.id and currency == ^"ZAR" and bucket_kind == :utc_hour and
          projection_state == :current and gross_ticket_quantity == 0
      )
      |> Ash.Query.limit(1)
      |> Ash.read_one!(domain: EventSales.Analytics)

    assert zero_hour != nil
  end

  test "yesterday becomes READY with explicit CURRENT zero Johannesburg day buckets", %{
    event: event,
    admin: admin
  } do
    assert {:ok, %{bucket_intents_created: created}} =
             PeriodCoverage.ensure_event_buckets(event.id, @now, enqueue_refresh?: false)

    assert created > 0
    assert {:ok, _} = SnapshotRefresh.refresh_event(event.id, now: @now)

    assert {:ok, result} =
             PeriodComparisonReader.compare_event(event.id, "ZAR", :yesterday,
               actor: admin,
               now: @now
             )

    assert result.current.readiness == :ready
    assert result.comparison.readiness == :ready

    zero_day =
      EventPeriodAggregateSnapshot
      |> Ash.Query.filter(
        event_id == ^event.id and currency == ^"ZAR" and
          bucket_kind == :johannesburg_day and projection_state == :current and
          gross_ticket_quantity == 0
      )
      |> Ash.Query.limit(1)
      |> Ash.read_one!(domain: EventSales.Analytics)

    assert zero_day != nil
    assert Decimal.equal?(result.current.metrics.net_ticket_quantity, Decimal.new("0"))
  end

  defp admin_user! do
    user =
      Ash.create!(
        User,
        %{
          email: "closure-admin-#{System.unique_integer()}@example.com",
          name: "Closure Admin",
          password: "valid-pass-123",
          password_confirmation: "valid-pass-123"
        },
        action: :register_with_password,
        domain: Accounts
      )

    role =
      Role
      |> Ash.Query.filter(name == ^:admin)
      |> Ash.read_one!(domain: Accounts)
      |> case do
        nil -> Ash.create!(Role, %{name: :admin}, action: :create, domain: Accounts)
        role -> role
      end

    Ash.create!(UserRole, %{user_id: user.id, role_id: role.id},
      action: :create,
      domain: Accounts
    )

    user
  end
end
