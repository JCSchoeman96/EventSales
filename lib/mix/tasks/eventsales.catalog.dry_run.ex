defmodule Mix.Tasks.Eventsales.Catalog.DryRun do
  @moduledoc """
  Runs a local full-feed Tickera catalogue dry run without Apply.
  """

  use Mix.Task

  alias EventSales.Maintenance.LocalCatalogDryRun

  @shortdoc "Runs the local signed catalogue dry-run integration"
  @default_expected_variation_ids [109_159, 109_162, 109_165, 109_167]

  @impl Mix.Task
  def run(args) do
    configure_safe_operator_logging()
    Mix.Task.run("app.start")

    opts = parse_args(args)

    case LocalCatalogDryRun.run(opts) do
      {:ok, result} ->
        Mix.shell().info("Run ID: #{result.run_id}")

        Mix.shell().info(
          "Run source: #{if(result.reused_existing_run, do: "reused", else: "new")}"
        )

        Mix.shell().info("Status: #{result.status}")
        Mix.shell().info("Findings: #{result.finding_summary.total}")
        Mix.shell().info("Blocking: #{result.finding_summary.blocking}")
        Mix.shell().info("Warnings: #{result.finding_summary.warning}")
        Mix.shell().info("Info: #{result.finding_summary.info}")
        Mix.shell().info("Finding codes:")
        Enum.each(result.finding_codes, &Mix.shell().info("- #{&1}"))
        Mix.shell().info("Variation IDs: #{length(result.variation_ids)}")
        Mix.shell().info("Expected variation IDs: present")
        Mix.shell().info("Apply: not invoked")

      {:error, reason} ->
        Mix.raise("catalogue dry run failed: #{format_error(reason)}")
    end
  end

  defp configure_safe_operator_logging do
    repo_config =
      Application.get_env(:event_sales, EventSales.Repo, [])
      |> Keyword.put(:log, false)
      |> Keyword.put(:show_sensitive_data_on_connection_error, false)

    Application.put_env(:event_sales, EventSales.Repo, repo_config)
    Logger.configure(level: :warning)
  end

  defp parse_args(args) do
    {parsed, remaining, invalid} =
      OptionParser.parse(args,
        strict: [source_system_id: :string, expected_variation_ids: :string]
      )

    if remaining != [] or invalid != [] do
      Mix.raise(
        "usage: mix eventsales.catalog.dry_run [--source-system-id UUID] " <>
          "[--expected-variation-ids ID,ID]"
      )
    end

    expected_ids =
      parsed
      |> Keyword.get(
        :expected_variation_ids,
        Enum.join(@default_expected_variation_ids, ",")
      )
      |> parse_expected_ids()

    parsed
    |> Keyword.delete(:expected_variation_ids)
    |> Keyword.put(:expected_variation_ids, expected_ids)
  end

  defp parse_expected_ids(value) do
    ids =
      value
      |> String.split(",", trim: true)
      |> Enum.map(fn raw ->
        case Integer.parse(String.trim(raw)) do
          {id, ""} when id > 0 -> id
          _other -> Mix.raise("expected variation IDs must be positive integers")
        end
      end)

    if ids == [], do: Mix.raise("at least one expected variation ID is required"), else: ids
  end

  defp format_error({:missing_expected_variation_ids, ids, run_id}),
    do: "run #{run_id} is missing expected variation IDs #{inspect(ids)}"

  defp format_error({:dry_run_not_ready, status, last_error}),
    do: "run ended in #{status}: #{last_error || "no safe error recorded"}"

  defp format_error(reason), do: inspect(reason)
end
