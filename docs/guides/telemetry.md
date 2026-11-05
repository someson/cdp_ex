# Telemetry

CDPEx emits [`:telemetry`](https://hexdocs.pm/telemetry) events and attaches no
handlers; attach your own to record them (emitting with nothing attached is a no-op).
Events: `[:cdp_ex, :launch, …]`, `[:cdp_ex, :connect, …]`, and
`[:cdp_ex, :navigate, …]` spans, `[:cdp_ex, :page, :start | :stop]`, and
`[:cdp_ex, :error]`. See `CDPEx.Telemetry`
([`lib/cdp_ex/telemetry.ex`](../../lib/cdp_ex/telemetry.ex)) for the full taxonomy
(measurements + metadata). The `[:cdp_ex, :page, …]` metadata carries `:transport`
and `:isolated`.

```elixir
:telemetry.attach(
  "cdp-nav",
  [:cdp_ex, :navigate, :stop],
  fn _event, %{duration: d}, %{url: url, status: status}, _config ->
    ms = System.convert_time_unit(d, :native, :millisecond)
    IO.puts("#{url} -> #{inspect(status)} in #{ms}ms")
  end,
  nil
)
```

`status` (and the post-redirect `final_url`) are `nil` unless the navigation used
`response: true` — see `CDPEx.Page.navigate/3`.
