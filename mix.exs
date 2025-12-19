defmodule Ocibuild.MixProject do
  use Mix.Project

  # Read metadata from app.src (single source of truth)
  @app_props (case :file.consult("src/ocibuild.app.src") do
                {:ok, [{:application, :ocibuild, props}]} -> props
                _ -> []
              end)

  @version to_string(Keyword.get(@app_props, :vsn, "0.0.0"))
  @description to_string(Keyword.get(@app_props, :description, ""))

  def project do
    [
      app: :ocibuild,
      version: @version,
      elixir: "~> 1.14",
      erlc_paths: ["src"],
      erlc_include_path: "include",
      elixirc_paths: ["lib"],
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: @description
    ]
  end

  def application, do: [extra_applications: [:crypto, :ssl, :inets]]

  defp deps, do: []
end
