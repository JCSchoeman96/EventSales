defmodule EventSales.Ingestion.TickeraCatalogAutoApplyConfig do
  @moduledoc "Deterministic composition and fingerprinting for catalog auto-Apply configuration."

  @spec effective_mode(map()) :: :disabled | :observe | :enabled
  def effective_mode(config) do
    effective_mode(
      config.hard_kill_enabled == true,
      config.global_mode,
      config.source_mode,
      config.source_allowlisted == true
    )
  end

  defp effective_mode(false, _global, _source, _allowlisted), do: :disabled
  defp effective_mode(true, :disabled, _source, _allowlisted), do: :disabled
  defp effective_mode(true, _global, :disabled, _allowlisted), do: :disabled
  defp effective_mode(true, :observe, _source, _allowlisted), do: :observe
  defp effective_mode(true, _global, :observe, _allowlisted), do: :observe
  defp effective_mode(true, _global, _source, false), do: :disabled

  defp effective_mode(true, :enabled, source, true) when source in [:enabled, :inherit],
    do: :enabled

  defp effective_mode(true, _global, _source, _allowlisted), do: :disabled

  @spec fingerprint(map()) :: String.t()
  def fingerprint(config) do
    policy_versions = config.enabled_policy_versions |> Enum.uniq() |> Enum.sort()
    snapshot_versions = config.supported_snapshot_versions |> Enum.uniq() |> Enum.sort()

    bytes =
      [
        "{",
        ~s("configuration_revision":),
        Integer.to_string(config.configuration_revision),
        ~s(,"enabled_policy_versions":),
        Jason.encode!(policy_versions),
        ~s(,"global_mode":),
        Jason.encode!(to_string(config.global_mode)),
        ~s(,"hard_kill_enabled":),
        Jason.encode!(config.hard_kill_enabled == true),
        ~s(,"source_allowlisted":),
        Jason.encode!(config.source_allowlisted == true),
        ~s(,"source_mode":),
        Jason.encode!(to_string(config.source_mode)),
        ~s(,"supported_snapshot_versions":),
        Jason.encode!(snapshot_versions),
        "}"
      ]
      |> IO.iodata_to_binary()

    bytes |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
  end

  def hard_kill do
    config =
      Application.get_env(:event_sales, :catalog_auto_apply,
        hard_enabled: false,
        health_error: nil
      )

    %{
      enabled: Keyword.get(config, :hard_enabled, false) == true,
      health_error: Keyword.get(config, :health_error)
    }
  end
end
