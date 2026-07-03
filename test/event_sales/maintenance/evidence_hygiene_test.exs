defmodule EventSales.Maintenance.EvidenceHygieneTest do
  use ExUnit.Case, async: true

  alias EventSales.Maintenance.{CutoverDryRun, ProductionSmoke}

  @secret_pattern ~r/(?i)(secret|password|consumer_key|consumer_secret|BEGIN PRIVATE KEY)/

  test "production smoke output never prints secret-like values" do
    lines =
      capture_output_lines(fn output ->
        assert_raise ProductionSmoke.Error, fn ->
          ProductionSmoke.run!(
            env: %{
              "EVENTSALES_BOOTSTRAP_ADMIN_EMAIL" => "admin@example.com",
              "EVENTSALES_BOOTSTRAP_ADMIN_PASSWORD" => "super-secret-password",
              "WEBHOOK_PATH_TOKEN" => "path-token-secret",
              "WOOCOMMERCE_WEBHOOK_SECRET" => "webhook-secret-value",
              "RAILWAY_PUBLIC_DOMAIN" => "example.com"
            },
            checks: [{"application", fn _ -> :error end}],
            output: output
          )
        end
      end)

    Enum.each(lines, fn line ->
      refute Regex.match?(@secret_pattern, line)
      refute line =~ "super-secret-password"
      refute line =~ "path-token-secret"
      refute line =~ "webhook-secret-value"
    end)
  end

  test "cutover dry run output never prints secret-like values" do
    lines =
      capture_output_lines(fn output ->
        assert_raise CutoverDryRun.Error, fn ->
          CutoverDryRun.run!(
            env: %{
              "EVENTSALES_BOOTSTRAP_ADMIN_EMAIL" => "admin@example.com",
              "EVENTSALES_BOOTSTRAP_ADMIN_PASSWORD" => "super-secret-password",
              "WEBHOOK_PATH_TOKEN" => "path-token-secret",
              "WOOCOMMERCE_WEBHOOK_SECRET" => "webhook-secret-value",
              "RAILWAY_PUBLIC_DOMAIN" => "example.com"
            },
            checks: [{"woocommerce rest configuration", fn _ -> :error end}],
            output: output
          )
        end
      end)

    Enum.each(lines, fn line ->
      refute Regex.match?(@secret_pattern, line)
      refute line =~ "super-secret-password"
      refute line =~ "path-token-secret"
      refute line =~ "webhook-secret-value"
    end)
  end

  defp capture_output_lines(fun) do
    lines = :ets.new(:evidence_hygiene_lines, [:set, :public])

    output = fn message ->
      :ets.insert(lines, {System.unique_integer([:positive]), to_string(message)})
    end

    fun.(output)

    :ets.tab2list(lines)
    |> Enum.sort_by(fn {id, _} -> id end)
    |> Enum.map(fn {_id, line} -> line end)
  end
end
