defmodule EventSales.Ingestion.TickeraCatalogAutoApplyConfig do
  @moduledoc "Deterministic composition and fingerprinting for catalog auto-Apply configuration."

  @spec effective_mode(map()) :: :disabled | :observe | :enabled
  def effective_mode(config) do
    cond do
      config.hard_kill_enabled != true -> :disabled
      config.global_mode == :disabled -> :disabled
      config.source_mode == :disabled -> :disabled
      config.global_mode == :observe -> :observe
      config.source_mode == :observe -> :observe
      config.source_allowlisted != true -> :disabled
      config.global_mode == :enabled and config.source_mode in [:enabled, :inherit] -> :enabled
      true -> :disabled
    end
  end

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
