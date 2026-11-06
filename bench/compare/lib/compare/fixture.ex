defmodule Compare.Fixture do
  @moduledoc "The fixture's URLs and what each page's ready state, text and click targets are."

  defstruct [:base, :embed, :proxy]
  @type t :: %__MODULE__{base: String.t(), embed: String.t(), proxy: String.t()}

  def from_env do
    %__MODULE__{
      base: System.get_env("BASE_URL", "http://site.test:8080"),
      embed: System.get_env("EMBED_URL", "http://embed.test:8080"),
      proxy: System.get_env("PROXY_URL", "http://site.test:3128")
    }
  end

  @pages %{
    "html" => %{path: "/html/", ready: :load, text: "#firstHeading", expect: "Saint Petersburg"},
    # One element each, so a library that checks every match (Wallaby checks
    # each one's visibility) isn't measured on 20 of them.
    "js" => %{
      path: "/js/",
      ready: {:css, ".article-preview:first-child"},
      text: ".article-preview:first-child h2",
      expect: "How to"
    },
    "heavy" => %{path: "/heavy/", ready: :load, text: "#headline", expect: "Morning edition"}
  }

  def pages, do: Map.keys(@pages)
  def page(name), do: Map.fetch!(@pages, name)
  def url(%__MODULE__{base: base}, name), do: base <> page(name).path

  # The click task: on /js/, open the first article and read its heading.
  def click_target, do: ".article-preview:first-child a.preview-link"
  def after_click, do: ".article-page h1"

  def log(%__MODULE__{base: base}) do
    {:ok, {{_, 200, _}, _, body}} = :httpc.request(String.to_charlist(base <> "/_log"))
    Jason.decode!(body)
  end

  def reset_log(%__MODULE__{base: base}) do
    {:ok, _} = :httpc.request(String.to_charlist(base <> "/_log/reset"))
    :ok
  end
end
