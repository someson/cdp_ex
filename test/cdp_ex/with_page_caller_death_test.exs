defmodule CDPEx.WithPageCallerDeathTest do
  # with_page/3 on a caller-owned browser (a pid, as Pool.with_page/3 passes) must
  # close its page when the caller dies mid-fun, with or without :deadline: the
  # browser outlives the caller, so nothing else would close the page (and its
  # isolated context). A stand-in Browser answers new_page/close_page and reports
  # each close.
  use ExUnit.Case, async: true

  alias CDPEx.Page

  defmodule StubBrowser do
    @moduledoc false
    use GenServer

    @impl true
    def init(test), do: {:ok, test}

    @impl true
    def handle_call({:new_page, _opts}, _from, test) do
      {:reply, {:ok, %Page{browser: self(), conn: self(), target_id: "T1"}}, test}
    end

    def handle_call({:close_page, page}, _from, test) do
      send(test, {:closed, page.target_id})
      {:reply, :ok, test}
    end
  end

  setup do
    {:ok, browser} = GenServer.start_link(StubBrowser, self())
    %{browser: browser}
  end

  for opts <- [[], [deadline: 60_000]] do
    test "a caller killed mid-fun gets its page closed (opts: #{inspect(opts)})", %{
      browser: browser
    } do
      test = self()

      caller =
        spawn(fn ->
          CDPEx.with_page(
            browser,
            fn _page ->
              send(test, :in_fun)
              Process.sleep(:infinity)
            end,
            unquote(opts)
          )
        end)

      assert_receive :in_fun, 5_000
      Process.exit(caller, :kill)
      assert_receive {:closed, "T1"}, 5_000
    end
  end

  test "a normal return closes the page once", %{browser: browser} do
    assert :done = CDPEx.with_page(browser, fn _ -> :done end)
    assert_receive {:closed, "T1"}
    refute_receive {:closed, _}, 200
  end
end
