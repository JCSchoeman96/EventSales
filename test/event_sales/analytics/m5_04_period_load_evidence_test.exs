# credo:disable-for-this-file Credo.Check.Readability.ModuleNames
defmodule EventSales.Analytics.M5_04PeriodLoadEvidenceTest do
  @moduledoc """
  Runs the M5-04 G2 load harness inside the test sandbox (not part of default CI timing gates).

  Invoke explicitly:

      bash scripts/dev_local.sh test test/event_sales/analytics/m5_04_period_load_evidence_test.exs
  """

  use EventSales.DataCase, async: false

  alias EventSales.TestSupport.UnboxedPostgres

  @tag :no_sandbox
  @tag :m5_04_certification_load
  @tag timeout: 600_000
  test "collects reader/rebuild load evidence" do
    samples =
      case System.get_env("M5_04_LOAD_SAMPLES") do
        nil -> 40
        value -> String.to_integer(value)
      end

    report =
      UnboxedPostgres.with_exclusive_setup(fn ->
        EventSales.TestSupport.M5_04PeriodLoadHarness.run!(samples: samples)
      end)

    path = Path.expand("tmp/m5_04_period_load_evidence.txt", File.cwd!())
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, :erlang.term_to_binary(report))

    assert report.reader_results != []
    assert report.samples_per_cohort == samples

    assert Enum.all?(report.reader_results, fn row ->
             row.errors == 0 and row.not_ready_count == 0
           end)
  end
end
