%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["config/", "lib/", "test/", "mix.exs"],
        excluded: [~r"/_build/", ~r"/deps/"]
      },
      strict: true,
      checks: %{
        disabled: [
          {Credo.Check.Design.AliasUsage, []},
          {Credo.Check.Design.TagTODO, []}
        ]
      }
    }
  ]
}
