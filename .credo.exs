%{
  configs: [
    %{
      name: "default",
      strict: true,
      files: %{
        included: ["lib/", "test/"],
        excluded: [~r"/_build/", ~r"/deps/"]
      },
      checks: %{
        enabled: [
          {Credo.Check.Readability.PipeIntoAnonymousFunctions, false},
          {Credo.Check.Refactor.PipeChainStart, false}
        ]
      }
    }
  ]
}
