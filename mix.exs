defmodule TermiteSsh.MixProject do
  use Mix.Project

  @source_url "https://github.com/Gazler/termite_ssh"

  def project do
    [
      app: :termite_ssh,
      version: "0.1.0",
      elixir: "~> 1.18",
      description: "SSH transport for Termite terminal applications",
      source_url: @source_url,
      package: package(),
      docs: docs(),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger, :ssh]]
  end

  defp deps do
    [
      {:termite, "~> 0.4 or ~> 1.0.0"},
      {:ex_doc, "~> 0.40.3", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      files: ["lib", ".formatter.exs", "mix.exs", "README.md"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md"],
      groups_for_modules: [
        "Public API": [Termite.SSH, Termite.SSH.Session],
        "Mix tasks": [Mix.Tasks.Termite.Ssh.GenHostKey]
      ]
    ]
  end
end
