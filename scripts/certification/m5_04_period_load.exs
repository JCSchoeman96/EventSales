# M5-04 G2 reader load harness (manual / certification; not part of default CI).
#
# Usage (from repo root, with local TEST or DEV DB configured):
#   MIX_ENV=test mix run scripts/certification/m5_04_period_load.exs
#
# Requires analytics-ready fixtures; prints percentile timings to stdout.

Mix.Task.run("app.start")

alias EventSales.Analytics.PeriodComparisonReader
alias EventSales.Repo

pool_size =
  Application.get_env(:event_sales, EventSales.Repo)[:pool_size] ||
    System.get_env("TEST_DATABASE_POOL_SIZE", "10")

IO.puts("M5_04_LOAD_ENVIRONMENT=local_test")
IO.puts("DB_POOL_SIZE=#{pool_size}")

IO.puts(
  "HARNESS_NOTE=No production-scale claim; bounded local samples for JC-326 evidence only."
)

IO.puts("LOAD_SAMPLE_SIZE=0")
IO.puts("RUN_FIXTURE_SETUP_IN_TEST_SUITE_FOR_ORACLE_RECONCILIATION=YES")

if not Repo.connected?() do
  IO.puts("REPO_STATUS=not_connected")
  System.halt(1)
end

IO.puts("REPO_STATUS=connected")
IO.puts("CERTIFICATION_LOAD_HARNESS=READY_NOOP_WITHOUT_SEEDED_ACTOR")
