defmodule Mix.Tasks.Eventsales.SourceSystem.BootstrapTest do
  use EventSales.DataCase, async: false

  import ExUnit.CaptureIO

  require Ash.Query

  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.SourceSystem

  @name_key "EVENTSALES_BOOTSTRAP_SOURCE_NAME"
  @base_url_key "EVENTSALES_BOOTSTRAP_SOURCE_BASE_URL"
  @name "Production WooCommerce"
  @base_url "https://shop.example.test"

  setup do
    for key <- [@name_key, @base_url_key] do
      original = System.get_env(key)
      on_exit(fn -> restore_env(key, original) end)
    end

    :ok
  end

  test "creates one normalized active WooCommerce source and prints safe status" do
    put_env(@name, "  #{@base_url}/  ")

    output = capture_io(fn -> Mix.Tasks.Eventsales.SourceSystem.Bootstrap.run([]) end)

    assert [%SourceSystem{} = source] = sources()
    assert source.name == @name
    assert source.kind == :woocommerce
    assert source.base_url == @base_url
    assert source.active
    assert output =~ "source system: #{@name}"
    assert output =~ "kind: woocommerce"
    assert output =~ "source: created"
    refute output =~ @base_url
  end

  test "is idempotent for an existing matching source" do
    put_env(@name, @base_url)

    capture_io(fn -> Mix.Tasks.Eventsales.SourceSystem.Bootstrap.run([]) end)
    output = capture_io(fn -> Mix.Tasks.Eventsales.SourceSystem.Bootstrap.run([]) end)

    assert length(sources()) == 1
    assert output =~ "source: existing"
  end

  test "reactivates and renames an existing source matched by normalized URL" do
    source =
      Ash.create!(
        SourceSystem,
        %{name: "Old Name", kind: :woocommerce, base_url: @base_url, active: false},
        action: :create,
        domain: Catalog
      )

    put_env(@name, "#{@base_url}/")

    output = capture_io(fn -> Mix.Tasks.Eventsales.SourceSystem.Bootstrap.run([]) end)
    updated = Ash.get!(SourceSystem, source.id, domain: Catalog)

    assert updated.name == @name
    assert updated.active
    assert output =~ "source: updated"
    assert length(sources()) == 1
  end

  test "refuses a missing or blank source name" do
    System.delete_env(@name_key)
    System.put_env(@base_url_key, @base_url)

    assert_raise Mix.Error, ~r/#{@name_key} is required/, fn ->
      capture_io(fn -> Mix.Tasks.Eventsales.SourceSystem.Bootstrap.run([]) end)
    end

    System.put_env(@name_key, "   ")

    assert_raise Mix.Error, ~r/#{@name_key} is required/, fn ->
      capture_io(fn -> Mix.Tasks.Eventsales.SourceSystem.Bootstrap.run([]) end)
    end
  end

  test "refuses a missing or blank source base URL without printing it" do
    System.put_env(@name_key, @name)
    System.delete_env(@base_url_key)

    assert_raise Mix.Error, ~r/#{@base_url_key} is required/, fn ->
      capture_io(fn -> Mix.Tasks.Eventsales.SourceSystem.Bootstrap.run([]) end)
    end

    System.put_env(@base_url_key, "   ")

    output =
      capture_io(:stderr, fn ->
        assert_raise Mix.Error, fn -> Mix.Tasks.Eventsales.SourceSystem.Bootstrap.run([]) end
      end)

    refute output =~ @base_url
  end

  defp put_env(name, base_url) do
    System.put_env(@name_key, name)
    System.put_env(@base_url_key, base_url)
  end

  defp sources do
    SourceSystem
    |> Ash.Query.filter(kind == :woocommerce)
    |> Ash.read!(domain: Catalog)
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
