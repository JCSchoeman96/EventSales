defmodule EventSales.Analytics.PeriodComparisonReaderIsolationTest do
  use EventSales.DataCase, async: false

  require Ash.Query

  alias EventSales.Accounts
  alias EventSales.Accounts.Resources.{Role, User, UserRole}
  alias EventSales.Analytics.PeriodComparisonReader
  alias EventSales.TestSupport.EventDetailCertificationHelpers
  alias EventSales.TestSupport.PeriodComparisonHelpers
  alias EventSales.TestSupport.SalesHelpers

  @now ~U[2026-05-17 10:00:00.000000Z]

  setup do
    source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{name: "Isolation target"})
    other_event = SalesHelpers.create_event!(source, %{name: "Isolation contaminant"})
    ticket = SalesHelpers.create_ticket_type!(event, %{name: "GA"})
    other_ticket = SalesHelpers.create_ticket_type!(other_event, %{name: "GA2"})
    admin = create_user!("period-isolation-admin@example.com")
    create_global_role!(admin, :admin)
    EventDetailCertificationHelpers.certify_analytics_ready!(event)
    EventDetailCertificationHelpers.certify_analytics_ready!(other_event)

    seed_attrs = %{
      current: %{gross_ticket_quantity: 5, gross_ticket_value: Decimal.new("50.00")},
      previous: %{gross_ticket_quantity: 1, gross_ticket_value: Decimal.new("10.00")}
    }

    PeriodComparisonHelpers.seed_comparison_projection!(
      event,
      source,
      ticket,
      "ZAR",
      :yesterday,
      @now,
      seed_attrs
    )

    PeriodComparisonHelpers.seed_comparison_projection!(
      other_event,
      source,
      other_ticket,
      "ZAR",
      :yesterday,
      @now,
      %{
        current: %{gross_ticket_quantity: 99, gross_ticket_value: Decimal.new("990.00")},
        previous: %{gross_ticket_quantity: 88, gross_ticket_value: Decimal.new("880.00")}
      }
    )

    PeriodComparisonHelpers.seed_comparison_projection!(
      event,
      source,
      ticket,
      "USD",
      :yesterday,
      @now,
      %{
        current: %{gross_ticket_quantity: 77, gross_ticket_value: Decimal.new("770.00")},
        previous: %{gross_ticket_quantity: 66, gross_ticket_value: Decimal.new("660.00")}
      }
    )

    %{
      event: event,
      other_event: other_event,
      ticket: ticket,
      admin: admin
    }
  end

  test "another event with identical bucket timestamps cannot contaminate ZAR totals", ctx do
    assert {:ok, result} =
             PeriodComparisonReader.compare_event(ctx.event.id, "ZAR", :yesterday,
               actor: ctx.admin,
               now: @now
             )

    assert result.current.readiness == :ready
    assert result.comparison.readiness == :ready
    assert Decimal.equal?(result.current.metrics.gross_ticket_quantity, Decimal.new("5"))
    assert result.event.metric_comparisons.gross_ticket_quantity.current == Decimal.new("5")

    for kind <- [:ticket_type, :source_product, :source_variation] do
      row = hd(Map.fetch!(result.dimensions, kind))
      assert row.metric_comparisons.gross_ticket_quantity.current == Decimal.new("5")
      refute row.metric_comparisons.gross_ticket_quantity.current == Decimal.new("99")
    end
  end

  test "same event different currency cannot contaminate requested currency", ctx do
    assert {:ok, result} =
             PeriodComparisonReader.compare_event(ctx.event.id, "ZAR", :yesterday,
               actor: ctx.admin,
               now: @now
             )

    assert result.current.readiness == :ready
    assert result.comparison.readiness == :ready
    refute Decimal.equal?(result.current.metrics.gross_ticket_quantity, Decimal.new("77"))
    assert Decimal.equal?(result.current.metrics.gross_ticket_quantity, Decimal.new("5"))

    for kind <- [:ticket_type, :source_product, :source_variation] do
      row = hd(Map.fetch!(result.dimensions, kind))
      assert row.metric_comparisons.gross_ticket_quantity.current == Decimal.new("5")
      refute row.metric_comparisons.gross_ticket_quantity.current == Decimal.new("77")
    end
  end

  defp create_user!(email) do
    Ash.create!(
      User,
      %{
        email: email,
        name: "Period Isolation User",
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
