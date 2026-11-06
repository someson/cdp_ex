defmodule Compare.MixProject do
  use Mix.Project

  def project do
    [app: :compare, version: "0.1.0", elixir: "~> 1.15", deps: deps()]
  end

  def application, do: [extra_applications: [:logger, :inets]]

  defp deps do
    [
      {:cdp_ex, path: "../.."},
      {:playwright_ex, "~> 0.16"},
      {:chromic_pdf, "~> 1.17"},
      # ChromicPDF needs it for chrome_address (the attach probe).
      {:websockex, "~> 0.5.1", override: true},
      {:wallaby, "~> 0.31", runtime: false}
    ]
  end
end
