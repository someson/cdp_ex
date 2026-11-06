defmodule Compare.Lib do
  @moduledoc """
  What every library adapter implements. A job function gets the adapter state,
  the worker index (0-based, below `opts[:parallel]`) and the task arguments.

  `ready` is `:load` or `{:css, selector}`: what "the page is ready" means for
  that page. Every job opens the page itself, so a job is one full unit of work.

  A job returns `{:ok, result}`, `{:partial, how, result}` (done, but only by a
  workaround outside the library's API) or `{:unsupported, why}`.
  """

  @type state :: term()
  @type ready :: :load | {:css, String.t()}
  @type result(t) :: {:ok, t} | {:partial, String.t(), t} | {:unsupported, String.t()}

  @callback name() :: String.t()
  @callback version() :: String.t()
  @callback start(opts :: keyword()) :: state()
  @callback stop(state()) :: :ok
  @callback screenshot(state(), worker :: non_neg_integer(), url :: String.t(), ready()) ::
              result(binary())
  @callback pdf(state(), non_neg_integer(), String.t(), ready()) :: result(binary())
  @callback text(state(), non_neg_integer(), String.t(), ready(), css :: String.t()) ::
              result(String.t())
  @callback click(
              state(),
              non_neg_integer(),
              String.t(),
              ready(),
              click :: String.t(),
              after_css :: String.t()
            ) :: result(String.t())
  @doc "Capabilities that aren't timed: name => fun returning a result."
  @callback probes(state(), Compare.Fixture.t()) :: [{atom(), (-> result(term()))}]

  def all, do: [Compare.CDPEx, Compare.PlaywrightEx, Compare.ChromicPDF, Compare.Wallaby]

  def by_name(name) do
    Enum.find(all(), &(&1.name() == name)) || raise "unknown library #{name}"
  end

  def dep_version(app), do: app |> Application.spec(:vsn) |> to_string()
end
