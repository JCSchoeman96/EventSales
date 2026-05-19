defmodule EventSales.Ingestion.TickeraEventSourcesTest do
  use EventSales.DataCase, async: false

  require Ash.Query

  alias EventSales.Accounts
  alias EventSales.Accounts.Resources.{Role, User, UserRole}
  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.TickeraEventSource
  alias EventSales.Ingestion.TickeraEventSources
  alias EventSales.TestSupport.SalesHelpers

  setup do
    original_env = Application.get_env(:event_sales, :env)

    admin = create_user!("tickera-source-admin@example.com")
    staff = create_user!("tickera-source-staff@example.com")
    create_global_role!(admin, :admin)
    create_global_role!(staff, :staff)

    source_system = SalesHelpers.create_source_system!()

    event =
      SalesHelpers.create_event!(source_system, %{
        name: "Tickera Source",
        slug: unique_slug("tickera-source")
      })

    on_exit(fn ->
      if is_nil(original_env) do
        Application.delete_env(:event_sales, :env)
      else
        Application.put_env(:event_sales, :env, original_env)
      end
    end)

    {:ok, admin: admin, staff: staff, source_system: source_system, event: event}
  end

  test "admin can create source and site URL is normalized", %{
    admin: admin,
    source_system: source_system,
    event: event
  } do
    assert {:ok, source} =
             TickeraEventSources.create_source(
               %{
                 source_system_id: source_system.id,
                 event_id: event.id,
                 tickera_site_url: " voelgoed.co.za/ ",
                 api_key_env_var: "TICKERA_API_KEY_VOELGOED_2026",
                 api_key_last4: "9f2a",
                 notes: "Main feed"
               },
               actor: admin
             )

    assert source.tickera_site_url == "https://voelgoed.co.za"
    assert source.api_key_env_var == "TICKERA_API_KEY_VOELGOED_2026"
    assert source.api_key_last4 == "9f2a"
    assert source.active
  end

  test "does not resolve api_key_env_var from System env", %{
    admin: admin,
    source_system: source_system,
    event: event
  } do
    System.put_env("TICKERA_API_KEY_SECRET_TEST", "plaintext-secret-value")
    on_exit(fn -> System.delete_env("TICKERA_API_KEY_SECRET_TEST") end)

    assert {:ok, source} =
             TickeraEventSources.create_source(
               %{
                 source_system_id: source_system.id,
                 event_id: event.id,
                 api_key_env_var: "TICKERA_API_KEY_SECRET_TEST"
               },
               actor: admin
             )

    assert inspect(source) =~ "TICKERA_API_KEY_SECRET_TEST"
    refute inspect(source) =~ "plaintext-secret-value"

    assert {:ok, fetched} = TickeraEventSources.get_source(source.id, actor: admin)
    refute inspect(fetched) =~ "plaintext-secret-value"
  end

  test "rejects http URL in prod", %{admin: admin, source_system: source_system, event: event} do
    Application.put_env(:event_sales, :env, :prod)

    assert {:error, %Ash.Error.Invalid{}} =
             TickeraEventSources.create_source(
               %{
                 source_system_id: source_system.id,
                 event_id: event.id,
                 tickera_site_url: "http://voelgoed.co.za",
                 api_key_env_var: "TICKERA_API_KEY_PROD"
               },
               actor: admin
             )
  end

  test "validates env var and api key display metadata", %{
    admin: admin,
    source_system: source_system,
    event: event
  } do
    for bad_env <- ["", "tickera_key", "1TICKERA_KEY", "TICKERA-KEY"] do
      assert {:error, %Ash.Error.Invalid{}} =
               TickeraEventSources.create_source(
                 %{
                   source_system_id: source_system.id,
                   event_id: event.id,
                   api_key_env_var: bad_env
                 },
                 actor: admin
               )
    end

    for bad_last4 <- [" abc ", "abcde"] do
      assert {:error, %Ash.Error.Invalid{}} =
               TickeraEventSources.create_source(
                 %{
                   source_system_id: source_system.id,
                   event_id: event.id,
                   api_key_env_var: "TICKERA_API_KEY_#{System.unique_integer([:positive])}",
                   api_key_last4: bad_last4
                 },
                 actor: admin
               )
    end
  end

  test "rejects forbidden api key fields", %{
    admin: admin,
    source_system: source_system,
    event: event
  } do
    for forbidden <- [%{api_key: "secret"}, %{tickera_api_key: "secret"}] do
      attrs =
        Map.merge(forbidden, %{
          source_system_id: source_system.id,
          event_id: event.id,
          api_key_env_var: "TICKERA_API_KEY_#{System.unique_integer([:positive])}"
        })

      assert {:error, %Ash.Error.Invalid{}} =
               TickeraEventSources.create_source(attrs, actor: admin)
    end
  end

  test "unique source per event and actor authorization", %{
    admin: admin,
    staff: staff,
    source_system: source_system,
    event: event
  } do
    attrs = %{
      source_system_id: source_system.id,
      event_id: event.id,
      api_key_env_var: "TICKERA_API_KEY_UNIQUE"
    }

    assert {:error, :forbidden} = TickeraEventSources.create_source(attrs, actor: nil)
    assert {:error, :forbidden} = TickeraEventSources.create_source(attrs, actor: staff)

    assert {:ok, source} = TickeraEventSources.create_source(attrs, actor: admin)
    assert {:error, %Ash.Error.Invalid{}} = TickeraEventSources.create_source(attrs, actor: admin)

    assert {:error, :forbidden} =
             TickeraEventSources.update_source(source, %{notes: "Nope"}, actor: staff)
  end

  test "direct Ash writes fail without authorization context", %{
    source_system: source_system,
    event: event
  } do
    assert {:error, %Ash.Error.Invalid{}} =
             TickeraEventSource
             |> Ash.Changeset.for_create(:create, %{
               source_system_id: source_system.id,
               event_id: event.id,
               api_key_env_var: "TICKERA_API_KEY_DIRECT"
             })
             |> Ash.create(domain: Ingestion)
  end

  test "activate, deactivate, and deterministic list ordering", %{
    admin: admin,
    source_system: source_system
  } do
    first_event =
      SalesHelpers.create_event!(source_system, %{name: "First", slug: unique_slug("first")})

    second_event =
      SalesHelpers.create_event!(source_system, %{name: "Second", slug: unique_slug("second")})

    {:ok, first} =
      TickeraEventSources.create_source(
        %{
          source_system_id: source_system.id,
          event_id: first_event.id,
          api_key_env_var: "TICKERA_API_KEY_FIRST"
        },
        actor: admin
      )

    {:ok, second} =
      TickeraEventSources.create_source(
        %{
          source_system_id: source_system.id,
          event_id: second_event.id,
          api_key_env_var: "TICKERA_API_KEY_SECOND"
        },
        actor: admin
      )

    assert {:ok, deactivated} = TickeraEventSources.deactivate_source(first, actor: admin)
    refute deactivated.active

    assert {:ok, activated} = TickeraEventSources.activate_source(deactivated, actor: admin)
    assert activated.active

    assert {:ok, [listed_second, listed_first]} =
             TickeraEventSources.list_sources(actor: admin, limit: 2)

    assert listed_second.id == second.id
    assert listed_first.id == activated.id
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
