Mix.Task.run("app.start")

unless Mix.env() == :test do
  Mix.raise("m5_04_period_load.exs must run with MIX_ENV=test")
end

alias Ecto.Adapters.SQL.Sandbox
alias EventSales.Repo

:ok = Sandbox.checkout(Repo)
Sandbox.mode(Repo, {:shared, self()})

samples =
  case System.get_env("M5_04_LOAD_SAMPLES") do
    nil -> 40
    value -> String.to_integer(value)
  end

report = EventSales.TestSupport.M5_04PeriodLoadHarness.run!(samples: samples)

path = Path.expand("tmp/m5_04_period_load_evidence.txt", File.cwd!())
File.mkdir_p!(Path.dirname(path))
File.write!(path, :erlang.term_to_binary(report))
