defmodule EventSales.TestSupport.TickeraSyncTestHelpers do
  @moduledoc false

  import ExUnit.Assertions

  alias EventSales.Accounts
  alias EventSales.Accounts.Resources.{Role, User, UserRole}
  alias EventSales.Ingestion.TickeraEventSources
  alias EventSales.TestSupport.Fakes.FakeTickeraAttendeeClient
  alias EventSales.TestSupport.SalesHelpers

  def setup_fake_client(_context) do
    start_supervised!(FakeTickeraAttendeeClient)

    original_client = Application.get_env(:event_sales, :tickera_attendee_client)

    Application.put_env(
      :event_sales,
      :tickera_attendee_client,
      FakeTickeraAttendeeClient
    )

    on_exit(fn ->
      if original_client do
        Application.put_env(:event_sales, :tickera_attendee_client, original_client)
      else
        Application.delete_env(:event_sales, :tickera_attendee_client)
      end

      FakeTickeraAttendeeClient.reset!({:ok, default_page_result()})
    end)

    :ok
  end

  def setup_admin(context) do
    admin = create_user!("tickera-sync-admin-#{System.unique_integer([:positive])}@example.com")
    create_global_role!(admin, :admin)

    source_system = SalesHelpers.create_source_system!()

    event =
      SalesHelpers.create_event!(source_system, %{
        name: "Tickera Sync",
        slug: unique_slug("tickera-sync")
      })

    env_var = "TICKERA_API_KEY_#{System.unique_integer([:positive])}"

    {:ok, source} =
      TickeraEventSources.create_source(
        %{
          source_system_id: source_system.id,
          event_id: event.id,
          api_key_env_var: env_var
        },
        actor: admin
      )

    Map.merge(context, %{
      admin: admin,
      source_system: source_system,
      event: event,
      source: source,
      env_var: env_var
    })
  end

  def attendee(overrides \\ %{}) do
    Map.merge(
      %{
        ticket_code: "TICKET-#{System.unique_integer([:positive])}",
        checksum: "CHK-#{System.unique_integer([:positive])}",
        ticket_type_id: 1,
        ticket_type: "General",
        first_name: "Jan",
        last_name: "Smit",
        email: "jan@example.com",
        buyer_first: "Buyer",
        buyer_last: "Person",
        buyer_email: "buyer@example.com",
        allowed_checkins: 1,
        used_checkins: 0,
        remaining_checkins: 1,
        checked_in: false,
        payment_status: "completed",
        payment_date: "2026-05-01",
        custom_fields: %{},
        transaction_id: "secret-txn-should-not-hash"
      },
      overrides
    )
  end

  def page_result(overrides \\ %{}) do
    attendees = Map.get(overrides, :attendees, [attendee()])
    page = Map.get(overrides, :page, 1)
    per_page = Map.get(overrides, :per_page, 50)
    count = Map.get(overrides, :count, length(attendees))

    Map.merge(
      %{
        attendees: attendees,
        page: page,
        per_page: per_page,
        count: count,
        additional: %{}
      },
      Map.drop(overrides, [:attendees, :page, :per_page, :count])
    )
  end

  def default_page_result, do: page_result(%{attendees: [], count: 0})

  def put_env!(key, value) do
    System.put_env(key, value)

    on_exit(fn ->
      System.delete_env(key)
    end)
  end

  def refute_secret_leaks!(value, secret) when is_binary(secret) and secret != "" do
    refute inspect(value) =~ secret
  end

  defp create_user!(email, password \\ "valid-pass-123") do
    Ash.create!(
      User,
      %{email: email, name: "Test User", password: password, password_confirmation: password},
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

  defp unique_slug(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
